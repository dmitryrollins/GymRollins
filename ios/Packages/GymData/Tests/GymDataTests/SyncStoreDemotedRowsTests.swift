import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// What a sign-out leaves behind and how the next sign-in settles it: the same account gets its rows back, another
/// account gets rows with ids of their own so they can never collide with the first account's server rows.
@MainActor
@Suite struct SyncStoreDemotedRowsTests {
    let f: SyncFixture
    let accountA = UUID(), accountB = UUID()
    init() throws { f = try SyncFixture() }

    private var repo: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }

    private func gymRecord(_ id: UUID) throws -> GymRecord? {
        try f.context.fetch(FetchDescriptor<GymRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func listingRecord(_ id: UUID) throws -> GymListingRecord? {
        try f.context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func acknowledgeAll() throws {
        for row in try f.store.dirtyGyms() {
            try f.store.markSynced(.gyms, id: row.value.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                                   serverUpdatedAt: f.clock.now)
        }
        for row in try f.store.dirtyGymListings() {
            try f.store.markSynced(.gymListings, id: row.value.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                                   serverUpdatedAt: f.clock.now)
        }
    }

    /// A synced gym with one clean synced listing and one `device` listing, owned by account A, then signed out.
    private func signedOutGym() throws -> (gym: Gym, synced: GymListing, device: GymListing) {
        f.store.ownerUserId = accountA
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        let synced = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", notes: "on the server"))
        let device = try repo.addListing(NewListing(gymId: gym.id, kindId: "dumbbells"))
        try repo.makeSynced(listing: synced.id)
        try acknowledgeAll()
        f.store.setCursor(f.clock.now, for: .gyms)
        f.store.setCursor(f.clock.now, for: .gymListings)
        _ = try f.store.resetAccountData()
        return (gym, synced, device)
    }

    private func pullBack(_ gym: Gym, _ synced: GymListing) throws {
        let at = f.clock.now
        try f.store.applyRemote(gyms: [SyncRow(
            value: SyncedGym(id: gym.id, name: "Home", address: nil, latitude: nil, longitude: nil),
            clientUpdatedAt: at, serverUpdatedAt: at)])
        try f.store.applyRemote(gymListings: [SyncRow(
            value: SyncedListing(id: synced.id, gymId: gym.id, kindId: "cable-stack", brand: nil, model: nil,
                                 loads: ListingLoads.none, quantity: 1, notes: "on the server", photoFile: nil,
                                 remotePhotoPath: nil),
            clientUpdatedAt: at, serverUpdatedAt: at)])
    }

    @Test func signingOutAndBackInBringsSyncedListingsBack() throws {
        defer { f.tearDown() }
        let (gym, synced, device) = try signedOutGym()
        #expect(try gymRecord(gym.id)?.demotedOwnerId == accountA)

        let moves = try f.store.settleDemotedRows(for: accountA)
        #expect(moves.isEmpty)
        #expect(try repo.gym(gym.id)?.visibility == .synced)
        #expect(try gymRecord(gym.id)?.demotedOwnerId == nil)
        #expect(try f.store.dirtyGyms().isEmpty)

        try pullBack(gym, synced)
        let ids = Set(try repo.listings(gymId: gym.id).map(\.id))
        #expect(ids == [synced.id, device.id])
        #expect(try repo.gym(gym.id)?.visibility == .synced)
        #expect(try listingRecord(device.id)?.visibilityRaw == GymVisibility.device.rawValue)
    }

    @Test func theCursorsDoNotSkipTheRestoredRows() throws {
        defer { f.tearDown() }
        _ = try signedOutGym()
        // A pull ran under another session and moved the cursors on; the restored rows must still be fetched.
        f.store.setCursor(f.clock.now.addingTimeInterval(500), for: .gyms)
        f.store.setCursor(f.clock.now.addingTimeInterval(500), for: .gymListings)
        try f.store.settleDemotedRows(for: accountA)
        #expect(f.store.cursor(for: .gyms) == nil)
        #expect(f.store.cursor(for: .gymListings) == nil)
    }

    @Test func anEditMadeBeforeSignOutIsPushedAfterSigningBackIn() throws {
        defer { f.tearDown() }
        f.store.ownerUserId = accountA
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        let listing = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", notes: "old"))
        try repo.makeSynced(listing: listing.id)
        try acknowledgeAll()
        f.clock.advance(60)
        try repo.updateListing(listing.id, loads: .none, quantity: 2, notes: "edited offline")
        _ = try f.store.resetAccountData()
        #expect(try f.store.dirtyGymListings().isEmpty, "while signed out nothing is pushed")

        try f.store.settleDemotedRows(for: accountA)
        let pending = try f.store.dirtyGymListings()
        #expect(pending.map(\.value.id) == [listing.id])
        #expect(pending.first?.value.notes == "edited offline")
        #expect(try repo.gym(gym.id)?.visibility == .synced)
    }

    @Test func aQueuedShareStaysOnThePhoneWhenTheSameAccountSignsBackIn() throws {
        defer { f.tearDown() }
        f.store.ownerUserId = accountA
        let maps = try repo.addMapsGym(placeId: "P1", name: "Maps", address: nil, latitude: 1, longitude: 2)
        let listing = try repo.addListing(NewListing(gymId: maps.id, kindId: "cable-stack"))
        let box = ShareOutbox(repository: repo, transport: FakeGymCatalogTransport(), photoData: { _ in nil },
                              now: { [clock = f.clock] in clock.now })
        try box.enqueueShare(listingId: listing.id, ownerId: accountA)
        _ = try f.store.resetAccountData()
        try f.store.settleDemotedRows(for: accountA)
        let row = try #require(try listingRecord(listing.id))
        #expect(row.visibilityRaw == GymVisibility.device.rawValue)
        #expect(row.uploadStateRaw == UploadState.local.rawValue)
        #expect(row.demotedOwnerId == nil)
        #expect(try f.store.dirtyGymListings().isEmpty)
    }

    @Test func anotherAccountGetsNewIdsAndCanSyncThem() throws {
        defer { f.tearDown() }
        let (gym, synced, device) = try signedOutGym()
        _ = try repo.addListing(NewListing(gymId: gym.id, kindId: "kettlebell")) // added while signed out
        let moves = try f.store.settleDemotedRows(for: accountB)

        let newGym = try #require(moves[gym.id])
        #expect(newGym != gym.id)
        #expect(try gymRecord(gym.id) == nil)
        let moved = try #require(try gymRecord(newGym))
        #expect(moved.visibilityRaw == GymVisibility.device.rawValue)
        #expect(moved.demotedOwnerId == nil && moved.serverUpdatedAt == nil && !moved.dirty)
        // Every listing at the gym follows it, and the one A's server knew has an id of its own as well.
        let at = try repo.listings(gymId: newGym)
        #expect(at.count == 2, "the synced one was removed at sign-out; the device and the new one stay")
        #expect(at.allSatisfy { $0.gymId == newGym })
        #expect(try listingRecord(device.id)?.gymId == newGym)
        #expect(try listingRecord(synced.id) == nil)

        // B syncs the gym: what goes up carries the new ids, not A's.
        try repo.makeSynced(gym: newGym)
        try repo.makeSynced(listing: device.id)
        #expect(try f.store.dirtyGyms().map(\.value.id) == [newGym])
        #expect(try f.store.dirtyGymListings().first?.value.gymId == newGym)
    }

    @Test func aDemotedListingGetsANewIdForAnotherAccount() throws {
        defer { f.tearDown() }
        f.store.ownerUserId = accountA
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        let listing = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        try repo.makeSynced(listing: listing.id) // never pushed: dirty, so it survives the sign-out
        _ = try f.store.resetAccountData()
        #expect(try listingRecord(listing.id)?.demotedOwnerId == accountA)

        let moves = try f.store.settleDemotedRows(for: accountB)
        #expect(moves.count == 1)
        #expect(try listingRecord(listing.id) == nil)
        let row = try #require(try f.context.fetch(FetchDescriptor<GymListingRecord>()).first)
        #expect(row.id != listing.id)
        #expect(row.gymId == moves[gym.id])
        #expect(row.visibilityRaw == GymVisibility.device.rawValue && !row.dirty && row.demotedOwnerId == nil)
    }

    @Test func aWorkoutLoggedWhileSignedOutFollowsTheGymAndListingToTheirNewIds() throws {
        defer { f.tearDown() }
        f.store.ownerUserId = accountA
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        let listing = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        try repo.makeSynced(listing: listing.id)
        _ = try f.store.resetAccountData()
        let base = sampleWorkout(at: f.clock.now)
        let w = base.with(entries: base.entries.map { $0.with(gymListingId: listing.id) }).with(gymId: gym.id)
        try f.workouts.save(w)

        let moves = try f.store.settleDemotedRows(for: accountB)
        let saved = try #require(try f.workouts.workout(w.id))
        #expect(saved.gymId == moves[gym.id])
        let newListing = try #require(try f.context.fetch(FetchDescriptor<GymListingRecord>()).first)
        #expect(saved.entries.first?.gymListingId == newListing.id)
    }

    @Test func aRowWithNoRecordedOwnerIsLeftAlone() throws {
        defer { f.tearDown() }
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        let listing = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        let moves = try f.store.settleDemotedRows(for: accountB)
        #expect(moves.isEmpty)
        #expect(try gymRecord(gym.id)?.visibilityRaw == GymVisibility.device.rawValue)
        #expect(try listingRecord(listing.id)?.gymId == gym.id)
    }

    @Test func settlingOnSignInForgetsWhenMapsGymsWereLastRefreshed() throws {
        defer { f.tearDown() }
        let maps = try repo.addMapsGym(placeId: "P1", name: "Maps", address: nil, latitude: 1, longitude: 2)
        try #require(try gymRecord(maps.id)).catalogRefreshedAt = f.clock.now
        try f.context.save()
        try f.store.settleDemotedRows(for: accountA)
        #expect(try gymRecord(maps.id)?.catalogRefreshedAt == nil)
    }

    // MARK: Server tombstones

    @Test func aTombstoneKeepsDeviceListings() throws {
        defer { f.tearDown() }
        let (gym, synced, device) = try signedOutGym()
        try f.store.settleDemotedRows(for: accountA)
        try pullBack(gym, synced)
        let at = f.clock.now.addingTimeInterval(900)
        let files = try f.store.applyRemote(gyms: [SyncRow(
            value: SyncedGym(id: gym.id, name: "Home", address: nil, latitude: nil, longitude: nil),
            clientUpdatedAt: at, deletedAt: at, serverUpdatedAt: at)])
        #expect(files.isEmpty)
        #expect(try listingRecord(synced.id) == nil)
        let kept = try #require(try listingRecord(device.id))
        #expect(try gymRecord(gym.id) == nil, "the old id names a deleted server row; nothing may reuse it")
        let home = try #require(try gymRecord(kept.gymId))
        #expect(home.visibilityRaw == GymVisibility.device.rawValue && home.serverUpdatedAt == nil)
        #expect(f.store.takeGymMoves() == [gym.id: kept.gymId])
        #expect(f.store.takeGymMoves().isEmpty)
    }

    @Test func aTombstoneForAGymThatWasNeverSignedOutBehavesTheSame() throws {
        defer { f.tearDown() }
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        let synced = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        let device = try repo.addListing(NewListing(gymId: gym.id, kindId: "dumbbells"))
        try repo.makeSynced(listing: synced.id)
        try acknowledgeAll()
        let at = f.clock.now.addingTimeInterval(900)
        try f.store.applyRemote(gyms: [SyncRow(
            value: SyncedGym(id: gym.id, name: "Home", address: nil, latitude: nil, longitude: nil),
            clientUpdatedAt: at, deletedAt: at, serverUpdatedAt: at)])
        let kept = try #require(try listingRecord(device.id))
        #expect(kept.gymId != gym.id)
        #expect(try gymRecord(kept.gymId)?.visibilityRaw == GymVisibility.device.rawValue)
        #expect(f.store.takeGymMoves() == [gym.id: kept.gymId])
    }

    @Test func aTombstoneForAGymWithNothingElseRemovesIt() throws {
        defer { f.tearDown() }
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        let synced = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        try repo.makeSynced(listing: synced.id)
        try acknowledgeAll()
        let at = f.clock.now.addingTimeInterval(900)
        try f.store.applyRemote(gyms: [SyncRow(
            value: SyncedGym(id: gym.id, name: "Home", address: nil, latitude: nil, longitude: nil),
            clientUpdatedAt: at, deletedAt: at, serverUpdatedAt: at)])
        #expect(try gymRecord(gym.id) == nil)
        #expect(f.store.takeGymMoves().isEmpty)
    }
}
