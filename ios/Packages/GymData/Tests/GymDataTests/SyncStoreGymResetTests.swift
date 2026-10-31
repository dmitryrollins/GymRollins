import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Decision 9: sign-out and the account switch keep what only this phone has.
@MainActor
@Suite struct SyncStoreGymResetTests {
    let f: SyncFixture
    let transport = FakeGymCatalogTransport()
    init() throws { f = try SyncFixture() }

    private var repo: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }

    private func listingRecord(_ id: UUID) throws -> GymListingRecord? {
        try f.context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func gymRecord(_ id: UUID) throws -> GymRecord? {
        try f.context.fetch(FetchDescriptor<GymRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func markClean(_ listing: UUID) throws {
        for row in try f.store.dirtyGymListings() where row.value.id == listing {
            try f.store.markSynced(.gymListings, id: listing.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                                   serverUpdatedAt: f.clock.now)
        }
        for row in try f.store.dirtyGyms() {
            try f.store.markSynced(.gyms, id: row.value.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                                   serverUpdatedAt: f.clock.now)
        }
    }

    @Test func deviceRowsAndTheirPhotosStay() throws {
        defer { f.tearDown() }
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        let listing = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", photoFile: "a.jpg"))
        let files = try f.store.resetAccountData()
        #expect(files.isEmpty)
        #expect(try gymRecord(gym.id) != nil)
        #expect(try listingRecord(listing.id)?.photoFile == "a.jpg")
    }

    @Test func cleanSyncedRowsAndTheirPhotosGo() throws {
        defer { f.tearDown() }
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        let listing = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", photoFile: "a.jpg"))
        try repo.makeSynced(listing: listing.id)
        try markClean(listing.id)
        f.store.setCursor(f.clock.now, for: .gyms)
        let files = try f.store.resetAccountData()
        #expect(files == ["a.jpg"])
        #expect(try gymRecord(gym.id) == nil)
        #expect(try listingRecord(listing.id) == nil)
        #expect(f.store.cursor(for: .gyms) == nil)
    }

    @Test func unpushedSyncedRowsFallBackToThisPhoneInsteadOfBeingLost() throws {
        defer { f.tearDown() }
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        let listing = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", photoFile: "a.jpg"))
        try repo.makeSynced(listing: listing.id)
        let files = try f.store.resetAccountData()
        #expect(files.isEmpty)
        #expect(try repo.gym(gym.id)?.visibility == .device)
        let kept = try #require(try listingRecord(listing.id))
        #expect(kept.visibilityRaw == GymVisibility.device.rawValue)
        #expect(kept.photoFile == "a.jpg")
        #expect(!kept.dirty)
        #expect(try f.store.dirtyGyms().isEmpty)
    }

    @Test func aSyncedGymWithADeviceListingStaysAsADeviceGym() throws {
        defer { f.tearDown() }
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        let synced = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", photoFile: "s.jpg"))
        let device = try repo.addListing(NewListing(gymId: gym.id, kindId: "dumbbells", photoFile: "d.jpg"))
        try repo.makeSynced(listing: synced.id)
        try markClean(synced.id)
        let files = try f.store.resetAccountData()
        #expect(files == ["s.jpg"])
        #expect(try repo.gym(gym.id)?.visibility == .device)
        #expect(try listingRecord(device.id)?.photoFile == "d.jpg")
        #expect(try listingRecord(synced.id) == nil)
    }

    @Test func cachedSharedRowsGoAndTheMapsGymStays() throws {
        defer { f.tearDown() }
        let maps = try repo.addMapsGym(placeId: "P1", name: "Maps", address: nil, latitude: 1, longitude: 2)
        let cached = try repo.addListing(NewListing(gymId: maps.id, kindId: "cable-stack", photoFile: "c.jpg"))
        let mine = try repo.addListing(NewListing(gymId: maps.id, kindId: "dumbbells", photoFile: "m.jpg"))
        let record = try #require(try listingRecord(cached.id))
        record.visibilityRaw = GymVisibility.shared.rawValue
        record.uploadStateRaw = UploadState.uploaded.rawValue
        try #require(try gymRecord(maps.id)).catalogRefreshedAt = f.clock.now
        try f.context.save()

        let files = try f.store.resetAccountData()
        #expect(files == ["c.jpg"])
        #expect(try listingRecord(cached.id) == nil)
        #expect(try listingRecord(mine.id)?.photoFile == "m.jpg")
        #expect(try gymRecord(maps.id)?.catalogRefreshedAt == nil)
    }

    @Test func aQueuedShareGoesBackToThisPhoneAndItsQueueRowGoes() throws {
        defer { f.tearDown() }
        let maps = try repo.addMapsGym(placeId: "P1", name: "Maps", address: nil, latitude: 1, longitude: 2)
        let listing = try repo.addListing(NewListing(gymId: maps.id, kindId: "cable-stack", photoFile: "q.jpg"))
        let box = ShareOutbox(repository: repo, transport: transport, photoData: { _ in nil },
                              now: { [clock = f.clock] in clock.now })
        try box.enqueueShare(listingId: listing.id, ownerId: UUID())
        try box.enqueueConfirm(listingId: UUID(), ownerId: UUID())
        #expect(box.pendingCount == 2)

        let files = try f.store.resetAccountData()
        #expect(files.isEmpty)
        #expect(box.pendingCount == 0)
        let row = try #require(try listingRecord(listing.id))
        #expect(row.visibilityRaw == GymVisibility.device.rawValue)
        #expect(row.uploadStateRaw == UploadState.local.rawValue)
        #expect(row.photoFile == "q.jpg")
    }

    @Test func resetAllStillRemovesEverything() throws {
        defer { f.tearDown() }
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        try f.store.resetAll()
        #expect(try f.context.fetchCount(FetchDescriptor<GymRecord>()) == 0)
        #expect(try f.context.fetchCount(FetchDescriptor<GymListingRecord>()) == 0)
    }
}
