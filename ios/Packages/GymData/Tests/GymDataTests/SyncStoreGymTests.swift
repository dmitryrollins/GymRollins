import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Private gyms and listings in the account (visibility `synced`): what is dirty, tombstones, remote rows.
@MainActor
@Suite struct SyncStoreGymTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    private var repo: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }

    private func syncedGym(brand: String? = nil, photo: String? = nil) throws -> (Gym, GymListing) {
        let gym = try repo.addPrivateGym(name: "Home", address: "Garage")
        let listing = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", brand: brand,
                                                     loads: .stack(maxKg: 90, stepKg: 5), photoFile: photo))
        try repo.makeSynced(listing: listing.id)
        return (gym, listing)
    }

    private func remoteGym(_ id: UUID = UUID(), name: String = "Away", at offset: TimeInterval = 600,
                           deleted: Bool = false) -> SyncRow<SyncedGym> {
        let at = f.clock.now.addingTimeInterval(offset)
        return SyncRow(value: SyncedGym(id: id, name: name, address: nil, latitude: nil, longitude: nil),
                       clientUpdatedAt: at, deletedAt: deleted ? at : nil, serverUpdatedAt: at)
    }

    private func remoteListing(_ id: UUID = UUID(), gym: UUID, brand: String? = nil, path: String? = nil,
                               at offset: TimeInterval = 600, deleted: Bool = false) -> SyncRow<SyncedListing> {
        let at = f.clock.now.addingTimeInterval(offset)
        let value = SyncedListing(id: id, gymId: gym, kindId: "cable-stack", brand: brand, model: nil,
                                  loads: .stack(maxKg: 80, stepKg: 5), quantity: 2, notes: "n", photoFile: nil,
                                  remotePhotoPath: path)
        return SyncRow(value: value, clientUpdatedAt: at, deletedAt: deleted ? at : nil, serverUpdatedAt: at)
    }

    private func gymRecord(_ id: UUID) throws -> GymRecord? {
        try f.context.fetch(FetchDescriptor<GymRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func listingRecord(_ id: UUID) throws -> GymListingRecord? {
        try f.context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: Dirty rows

    @Test func onlySyncedRowsAreDirty() throws {
        defer { f.tearDown() }
        let home = try repo.addPrivateGym(name: "Device", address: nil)
        try repo.addListing(NewListing(gymId: home.id, kindId: "cable-stack"))
        let maps = try repo.addMapsGym(placeId: "P1", name: "Maps", address: nil, latitude: 1, longitude: 2)
        let shared = try repo.addListing(NewListing(gymId: maps.id, kindId: "cable-stack"))
        let record = try #require(try listingRecord(shared.id))
        record.visibilityRaw = GymVisibility.shared.rawValue
        record.dirty = true
        try f.context.save()
        #expect(try f.store.dirtyGyms().isEmpty)
        #expect(try f.store.dirtyGymListings().isEmpty)

        let (gym, listing) = try syncedGym(brand: "Hammer")
        let gyms = try f.store.dirtyGyms()
        #expect(gyms.map(\.value.id) == [gym.id])
        #expect(gyms.first?.value.address == "Garage")
        let listings = try f.store.dirtyGymListings()
        #expect(listings.map(\.value.id) == [listing.id])
        #expect(listings.first?.value.brand == "Hammer")
        #expect(listings.first?.value.loads == .stack(maxKg: 90, stepKg: 5))
    }

    @Test func markSyncedClearsDirtyOnlyForTheSameEdit() throws {
        defer { f.tearDown() }
        let (gym, listing) = try syncedGym()
        let gymRow = try #require(try f.store.dirtyGyms().first)
        f.clock.advance()
        try repo.updateGym(gym.id, name: "Home 2", address: nil)
        try f.store.markSynced(.gyms, id: gym.id.uuidString, clientUpdatedAt: gymRow.clientUpdatedAt,
                               serverUpdatedAt: f.clock.now)
        #expect(try f.store.dirtyGyms().map(\.value.name) == ["Home 2"])

        let row = try #require(try f.store.dirtyGymListings().first)
        try f.store.markSynced(.gymListings, id: listing.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                               serverUpdatedAt: f.clock.now)
        #expect(try f.store.dirtyGymListings().isEmpty)
    }

    @Test func editingASyncedListingMarksItDirtyAgain() throws {
        defer { f.tearDown() }
        let (_, listing) = try syncedGym()
        let row = try #require(try f.store.dirtyGymListings().first)
        try f.store.markSynced(.gymListings, id: listing.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                               serverUpdatedAt: f.clock.now)
        f.clock.advance()
        try repo.updateListing(listing.id, loads: .stack(maxKg: 100, stepKg: 5), quantity: 3, notes: nil)
        #expect(try f.store.dirtyGymListings().map(\.value.quantity) == [3])
    }

    // MARK: Making rows synced

    @Test func makingAGymSyncedMarksItAndItsSyncedListingsAndLeavesDeviceListingsAlone() throws {
        defer { f.tearDown() }
        let (gym, synced) = try syncedGym()
        let device = try repo.addListing(NewListing(gymId: gym.id, kindId: "dumbbells"))
        for row in try f.store.dirtyGymListings() {
            try f.store.markSynced(.gymListings, id: row.value.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                                   serverUpdatedAt: f.clock.now)
        }
        f.clock.advance()
        try repo.makeSynced(gym: gym.id)
        #expect(try f.store.dirtyGyms().map(\.value.id) == [gym.id])
        #expect(try f.store.dirtyGymListings().map(\.value.id) == [synced.id])
        #expect(try listingRecord(device.id)?.visibilityRaw == GymVisibility.device.rawValue)
    }

    @Test func syncingAListingSyncsItsGym() throws {
        defer { f.tearDown() }
        let (gym, _) = try syncedGym()
        #expect(try repo.gym(gym.id)?.visibility == .synced)
    }

    @Test func aMapsGymCannotBeSynced() throws {
        defer { f.tearDown() }
        let maps = try repo.addMapsGym(placeId: "P1", name: "Maps", address: nil, latitude: 1, longitude: 2)
        let listing = try repo.addListing(NewListing(gymId: maps.id, kindId: "cable-stack"))
        #expect(throws: GymDataError.self) { try repo.makeSynced(gym: maps.id) }
        #expect(throws: GymDataError.self) { try repo.makeSynced(listing: listing.id) }
        #expect(try repo.gym(maps.id)?.visibility == .device)
        #expect(try f.store.dirtyGyms().isEmpty)
    }

    // MARK: Tombstones

    @Test func deletingASyncedListingLeavesATombstoneUntilItIsPushed() throws {
        defer { f.tearDown() }
        let (gym, listing) = try syncedGym(photo: "a.jpg")
        let row = try #require(try f.store.dirtyGymListings().first)
        try f.store.markSynced(.gymListings, id: listing.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                               serverUpdatedAt: f.clock.now)
        f.clock.advance()
        #expect(try repo.removeListing(listing.id) == "a.jpg")
        #expect(try repo.listings(gymId: gym.id).isEmpty)
        let tombstone = try #require(try f.store.dirtyGymListings().first)
        #expect(tombstone.deletedAt != nil)

        try f.store.markSynced(.gymListings, id: listing.id.uuidString, clientUpdatedAt: tombstone.clientUpdatedAt,
                               serverUpdatedAt: f.clock.now)
        #expect(try listingRecord(listing.id) == nil)
    }

    @Test func deletingASyncedGymTombstonesItAndItsSyncedListingsButDropsDeviceListings() throws {
        defer { f.tearDown() }
        let (gym, listing) = try syncedGym(photo: "a.jpg")
        let device = try repo.addListing(NewListing(gymId: gym.id, kindId: "dumbbells", photoFile: "b.jpg"))
        let photos = try repo.deleteGym(gym.id)
        #expect(Set(photos) == ["a.jpg", "b.jpg"])
        #expect(try repo.gyms().isEmpty)
        #expect(try listingRecord(device.id) == nil)
        #expect(try listingRecord(listing.id)?.deletedAt != nil)
        #expect(try f.store.dirtyGyms().first?.deletedAt != nil)
        #expect(try f.store.dirtyGymListings().first?.deletedAt != nil)
    }

    @Test func deletingADeviceRowRemovesItAtOnce() throws {
        defer { f.tearDown() }
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        let listing = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        try repo.removeListing(listing.id)
        #expect(try listingRecord(listing.id) == nil)
        _ = try repo.deleteGym(gym.id)
        #expect(try gymRecord(gym.id) == nil)
    }

    // MARK: Remote rows

    @Test func remoteGymsAreInsertedUpdatedAndRemoved() throws {
        defer { f.tearDown() }
        let id = UUID()
        try f.store.applyRemote(gyms: [remoteGym(id, name: "Away")])
        let created = try #require(try repo.gym(id))
        #expect(created.name == "Away")
        #expect(created.visibility == .synced)
        #expect(try f.store.dirtyGyms().isEmpty)

        try f.store.applyRemote(gyms: [remoteGym(id, name: "Away 2", at: 700)])
        #expect(try repo.gym(id)?.name == "Away 2")

        try f.store.applyRemote(gyms: [remoteGym(id, at: 800, deleted: true)])
        #expect(try gymRecord(id) == nil)
    }

    @Test func aRemoteTombstoneForAnUnknownRowIsIgnored() throws {
        defer { f.tearDown() }
        try f.store.applyRemote(gyms: [remoteGym(deleted: true)])
        #expect(try f.context.fetchCount(FetchDescriptor<GymRecord>()) == 0)
    }

    @Test func aDirtyLocalEditBeatsAnOlderRemoteRow() throws {
        defer { f.tearDown() }
        let (gym, _) = try syncedGym()
        f.clock.advance(1_000)
        try repo.updateGym(gym.id, name: "Mine", address: nil)
        try f.store.applyRemote(gyms: [remoteGym(gym.id, name: "Theirs", at: -10)])
        #expect(try repo.gym(gym.id)?.name == "Mine")
    }

    @Test func remoteListingsComeBackWithTheirBrandAndLoads() throws {
        defer { f.tearDown() }
        let gym = UUID(), id = UUID()
        try f.store.applyRemote(gyms: [remoteGym(gym)])
        let files = try f.store.applyRemote(gymListings: [remoteListing(id, gym: gym, brand: "Hammer", path: "p.jpg")])
        #expect(files.isEmpty)
        let listing = try #require(try repo.listings(gymId: gym).first)
        #expect(listing.id == id)
        #expect(listing.item.brand == "Hammer")
        #expect(listing.item.kindId == "cable-stack")
        #expect(listing.loads == .stack(maxKg: 80, stepKg: 5))
        #expect(listing.quantity == 2)
        #expect(listing.visibility == .synced)
        #expect(try f.store.dirtyGymListings().isEmpty)
        #expect(try listingRecord(id)?.remotePhotoPath == "p.jpg")
    }

    @Test func aRemoteListingTombstoneRemovesTheRowAndReturnsItsPhotoFile() throws {
        defer { f.tearDown() }
        let gym = UUID(), id = UUID()
        try f.store.applyRemote(gyms: [remoteGym(gym)])
        try f.store.applyRemote(gymListings: [remoteListing(id, gym: gym, path: "p.jpg")])
        try f.store.setPhotoFile(listingId: id, file: "local.jpg")
        let files = try f.store.applyRemote(gymListings: [remoteListing(id, gym: gym, at: 900, deleted: true)])
        #expect(files == ["local.jpg"])
        #expect(try listingRecord(id) == nil)
    }

    @Test func aChangedRemotePhotoDropsTheLocalFileSoItIsFetchedAgain() throws {
        defer { f.tearDown() }
        let gym = UUID(), id = UUID()
        try f.store.applyRemote(gyms: [remoteGym(gym)])
        try f.store.applyRemote(gymListings: [remoteListing(id, gym: gym, path: "one.jpg")])
        #expect(try f.store.listingsMissingPhoto() == [PhotoFetch(listingId: id, path: "one.jpg")])
        try f.store.setPhotoFile(listingId: id, file: "one-local.jpg")
        #expect(try f.store.listingsMissingPhoto().isEmpty)

        let files = try f.store.applyRemote(gymListings: [remoteListing(id, gym: gym, path: "two.jpg", at: 700)])
        #expect(files == ["one-local.jpg"])
        #expect(try f.store.listingsMissingPhoto() == [PhotoFetch(listingId: id, path: "two.jpg")])
    }

    @Test func aPhotoThatLostToTheRemoteCopyStaysDirtySoItUploads() async throws {
        defer { f.tearDown() }
        let (gym, listing) = try syncedGym(photo: "mine.jpg")
        f.clock.advance(1_000)
        let files = try f.store.applyRemote(gymListings: [remoteListing(listing.id, gym: gym.id, at: 5_000)])
        #expect(files.isEmpty)
        let row = try #require(try f.store.dirtyGymListings().first)
        #expect(row.value.id == listing.id && row.value.photoFile == "mine.jpg" && row.value.remotePhotoPath == nil)
    }

    @Test func aCleanListingWithoutAPhotoPathIsNotMadeDirtyByAPull() throws {
        defer { f.tearDown() }
        let gym = UUID(), id = UUID()
        try f.store.applyRemote(gyms: [remoteGym(gym)])
        try f.store.applyRemote(gymListings: [remoteListing(id, gym: gym)])
        try f.store.setPhotoFile(listingId: id, file: "local.jpg")
        try f.store.applyRemote(gymListings: [remoteListing(id, gym: gym, at: 900)])
        #expect(try f.store.dirtyGymListings().isEmpty)
    }

    @Test func remoteRowsNeverTouchDeviceOrSharedRows() throws {
        defer { f.tearDown() }
        let device = try repo.addPrivateGym(name: "Mine", address: nil)
        let maps = try repo.addMapsGym(placeId: "P1", name: "Maps", address: nil, latitude: 1, longitude: 2)
        let shared = try repo.addListing(NewListing(gymId: maps.id, kindId: "cable-stack", notes: "local"))
        let record = try #require(try listingRecord(shared.id))
        record.visibilityRaw = GymVisibility.shared.rawValue
        let deviceListing = try repo.addListing(NewListing(gymId: device.id, kindId: "cable-stack", notes: "local"))

        try f.store.applyRemote(gyms: [remoteGym(device.id, name: "Hijacked"),
                                       remoteGym(maps.id, name: "Hijacked", at: 700, deleted: true)])
        let files = try f.store.applyRemote(gymListings: [
            remoteListing(shared.id, gym: maps.id, at: 700, deleted: true),
            remoteListing(deviceListing.id, gym: device.id, at: 700, deleted: true),
        ])
        #expect(files.isEmpty)
        #expect(try repo.gym(device.id)?.name == "Mine")
        #expect(try repo.gym(maps.id)?.name == "Maps")
        #expect(try listingRecord(shared.id)?.notes == "local")
        #expect(try listingRecord(deviceListing.id)?.notes == "local")
    }

    // MARK: Account data

    @Test func syncedRowsCountAsAccountData() throws {
        defer { f.tearDown() }
        let device = try repo.addPrivateGym(name: "Device", address: nil)
        try repo.addListing(NewListing(gymId: device.id, kindId: "cable-stack"))
        #expect(try !f.store.hasLocalData())
        _ = try syncedGym()
        #expect(try f.store.hasLocalData())
    }
}

/// A private row whose loads this version can't read is kept as it is and not sent back (its fields would overwrite
/// newer loads on the server).
@MainActor
@Suite struct SyncStoreUnsupportedLoadsTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    private var repo: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }

    private func pullUnreadable() throws -> (gym: UUID, listing: UUID) {
        let gym = UUID(), listing = UUID(), at = f.clock.now.addingTimeInterval(600)
        try f.store.applyRemote(gyms: [SyncRow(
            value: SyncedGym(id: gym, name: "Away", address: nil, latitude: nil, longitude: nil),
            clientUpdatedAt: at, serverUpdatedAt: at)])
        try f.store.applyRemote(gymListings: [SyncRow(
            value: SyncedListing(id: listing, gymId: gym, kindId: "cable-stack", brand: nil, model: nil, loads: nil,
                                 quantity: 1, notes: "n", photoFile: nil, remotePhotoPath: nil),
            clientUpdatedAt: at, serverUpdatedAt: at)])
        return (gym, listing)
    }

    private func record(_ id: UUID) throws -> GymListingRecord {
        try #require(try f.context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first)
    }

    @Test func aPulledRowWithUnreadableLoadsIsUnsupportedNotNone() throws {
        defer { f.tearDown() }
        let (_, listing) = try pullUnreadable()
        #expect(try record(listing).statusRaw == ListingStatus.unsupported.rawValue)
        #expect(try repo.listings(gymId: try #require(try record(listing).gymId)).isEmpty, "the rules don't see it")
    }

    @Test func itsLocalEditsAreNotPushedButItsDeletionIs() throws {
        defer { f.tearDown() }
        let (_, listing) = try pullUnreadable()
        f.clock.advance(1_000)
        let row = try record(listing)
        row.notes = "edited here"
        row.updatedAt = f.clock.now
        row.dirty = true
        #expect(try f.store.dirtyGymListings().isEmpty)

        f.clock.advance(60)
        _ = try repo.removeListing(listing)
        let tombstone = try #require(try f.store.dirtyGymListings().first)
        #expect(tombstone.deletedAt != nil && tombstone.value.loads == nil)
    }

    @Test func aLaterReadableVersionOfTheRowIsSupportedAgain() throws {
        defer { f.tearDown() }
        let (gym, listing) = try pullUnreadable()
        let at = f.clock.now.addingTimeInterval(900)
        try f.store.applyRemote(gymListings: [SyncRow(
            value: SyncedListing(id: listing, gymId: gym, kindId: "cable-stack", brand: nil, model: nil,
                                 loads: .stack(maxKg: 90, stepKg: 5), quantity: 1, notes: "n", photoFile: nil,
                                 remotePhotoPath: nil),
            clientUpdatedAt: at, serverUpdatedAt: at)])
        #expect(try record(listing).statusRaw == ListingStatus.active.rawValue)
        #expect(try repo.listings(gymId: gym).first?.loads == .stack(maxKg: 90, stepKg: 5))
    }
}
