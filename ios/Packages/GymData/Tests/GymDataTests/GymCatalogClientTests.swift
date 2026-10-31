import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

@MainActor
@Suite struct GymCatalogClientTests {
    let f: SyncFixture
    let transport = FakeGymCatalogTransport()
    let serverGymId = UUID()
    init() throws { f = try SyncFixture() }

    private var repo: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }
    private var client: GymCatalogClient {
        GymCatalogClient(repository: repo, transport: transport, knownKinds: ["cable-stack", "kettlebell"],
                         now: { [clock = f.clock] in clock.now })
    }

    private func mapsGym(remoteId: UUID? = nil) throws -> Gym {
        let gym = try repo.addMapsGym(placeId: "P1", name: "Apple Name", address: "1 Main", latitude: 1, longitude: 2)
        if let remoteId { try gymRecord(gym.id).remoteId = remoteId }
        return gym
    }

    private func gymRecord(_ id: UUID) throws -> GymRecord {
        try #require(try f.context.fetch(FetchDescriptor<GymRecord>(predicate: #Predicate { $0.id == id })).first)
    }

    private func listingRecord(_ id: UUID) throws -> GymListingRecord? {
        try f.context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func remote(id: UUID = UUID(), item: UUID = UUID(), kind: String = "cable-stack", brand: String? = nil,
                        loads: ListingLoads? = .stack(maxKg: 90, stepKg: 5), photo: String? = nil,
                        mine: Bool = false, status: String = "active") -> RemoteListing {
        RemoteListing(id: id, gymId: serverGymId, itemId: item, kindId: kind, brand: brand, model: nil,
                      photoPath: photo, loads: loads, quantity: 2, notes: "n", status: status, confirmCount: 3,
                      isMine: mine, confirmedByMe: false)
    }

    private func serverHasGym() {
        transport.gym = RemoteGym(id: serverGymId, name: "Server Name", address: "Elsewhere", latitude: 9,
                                  longitude: 9, mapsPlaceId: "P1")
    }

    @Test func refreshCachesPublicListingsAsLocalRows() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        serverHasGym()
        let a = remote(photo: "\(UUID()).jpg"), b = remote(kind: "kettlebell", loads: .fixed(kg: [16]), mine: true)
        transport.listings = [a, b]
        let result = try await client.refresh(gymId: gym.id, force: false)
        #expect(try gymRecord(gym.id).remoteId == serverGymId)
        let rows = try repo.listings(gymId: gym.id)
        #expect(rows.count == 2)
        let cachedA = try #require(rows.first { $0.id == a.id })
        #expect(cachedA.visibility == .shared)
        #expect(cachedA.uploadState == .uploaded)
        #expect(cachedA.remoteId == a.id)
        #expect(cachedA.isOwn == false)
        #expect(cachedA.confirmCount == 3)
        #expect(try #require(rows.first { $0.id == b.id }).isOwn)
        #expect(result.photosToFetch == [PhotoFetch(listingId: a.id, path: a.photoPath!)])
    }

    @Test func aDeviceListingAtTheGymIsLeftAlone() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        let mine = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", photoFile: "mine.jpg"))
        transport.listings = [remote()]
        let result = try await client.refresh(gymId: gym.id, force: true)
        let kept = try #require(try repo.listing(mine.id))
        #expect(kept.visibility == .device)
        #expect(kept.photoFile == "mine.jpg")
        #expect(try repo.listings(gymId: gym.id).count == 2)
        #expect(result.filesToDelete.isEmpty)
    }

    /// A cached shared listing of the user's own, on the server, that a refresh would delete if it were missing.
    private func cachedOwnListing(at gym: Gym) throws -> RemoteListing {
        let own = remote(mine: true)
        transport.listings = [own]
        return own
    }

    @Test func rowsTheAppCouldNotReadDeleteNothingAndDoNotStamp() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        let own = try cachedOwnListing(at: gym)
        _ = try await client.refresh(gymId: gym.id, force: true)
        let fresh = remote(kind: "kettlebell", loads: .fixed(kg: [16]))
        try gymRecord(gym.id).catalogRefreshedAt = nil
        transport.listings = [fresh] // `own` is missing, as it would be if its row failed to decode
        transport.skipped = 1
        let result = try await client.refresh(gymId: gym.id, force: true)
        #expect(try listingRecord(own.id) != nil)
        #expect(try listingRecord(fresh.id) != nil)
        #expect(result.filesToDelete.isEmpty)
        #expect(try gymRecord(gym.id).catalogRefreshedAt == nil)
    }

    @Test func aCappedReadDeletesNothingAndDoesNotStamp() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        let own = try cachedOwnListing(at: gym)
        _ = try await client.refresh(gymId: gym.id, force: true)
        try gymRecord(gym.id).catalogRefreshedAt = nil
        transport.listings = []
        transport.capped = true
        _ = try await client.refresh(gymId: gym.id, force: true)
        #expect(try listingRecord(own.id) != nil)
        #expect(try gymRecord(gym.id).catalogRefreshedAt == nil)
    }

    @Test func noKnownKindsDeleteNothingAndDoNotStamp() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        let own = try cachedOwnListing(at: gym)
        _ = try await client.refresh(gymId: gym.id, force: true)
        try gymRecord(gym.id).catalogRefreshedAt = nil
        // The equipment catalog failed to load, so every kind reads as unknown.
        let blind = GymCatalogClient(repository: repo, transport: transport, knownKinds: [],
                                     now: { [clock = f.clock] in clock.now })
        _ = try await blind.refresh(gymId: gym.id, force: true)
        #expect(try listingRecord(own.id) != nil)
        #expect(try gymRecord(gym.id).catalogRefreshedAt == nil)
    }

    @Test func aCompleteReadStillRemovesWhatIsGoneAndStamps() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        let own = try cachedOwnListing(at: gym)
        _ = try await client.refresh(gymId: gym.id, force: true)
        transport.listings = []
        _ = try await client.refresh(gymId: gym.id, force: true)
        #expect(try listingRecord(own.id) == nil)
        #expect(try gymRecord(gym.id).catalogRefreshedAt != nil)
    }

    @Test func aListingGoneFromTheServerIsRemovedLocallyAndItsPhotoReturned() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        let gone = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", photoFile: "gone.jpg"))
        let queued = try repo.addListing(NewListing(gymId: gym.id, kindId: "kettlebell"))
        let device = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        for id in [gone.id, queued.id] { try #require(try listingRecord(id)).visibilityRaw = GymVisibility.shared.rawValue }
        try #require(try listingRecord(gone.id)).uploadStateRaw = UploadState.uploaded.rawValue
        try #require(try listingRecord(queued.id)).uploadStateRaw = UploadState.queued.rawValue
        let result = try await client.refresh(gymId: gym.id, force: true)
        #expect(try listingRecord(gone.id) == nil)
        #expect(try listingRecord(queued.id) != nil)
        #expect(try listingRecord(device.id) != nil)
        #expect(result.filesToDelete == ["gone.jpg"])
    }

    @Test func aListingWithAnUnreadableLoadsShapeIsKeptButNotUsable() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        let odd = remote(loads: nil), fine = remote()
        transport.listings = [odd, fine]
        _ = try await client.refresh(gymId: gym.id, force: true)
        #expect(try #require(try listingRecord(odd.id)).statusRaw == ListingStatus.unsupported.rawValue)
        #expect(try repo.inventory(gymId: gym.id).listings.map(\.id) == [fine.id])
    }

    @Test func anUnknownKindIsLeftOutOfTheInventory() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        let unknown = remote(kind: "hover-board"), fine = remote()
        transport.listings = [unknown, fine]
        _ = try await client.refresh(gymId: gym.id, force: true)
        #expect(try repo.inventory(gymId: gym.id).listings.map(\.id) == [fine.id])
        #expect(try listingRecord(unknown.id) == nil)
    }

    @Test func aPrivateGymNeverCallsTheServer() async throws {
        defer { f.tearDown() }
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        _ = try await client.refresh(gymId: gym.id, force: true)
        try gymRecord(gym.id).visibilityRaw = GymVisibility.synced.rawValue
        _ = try await client.refresh(gymId: gym.id, force: true)
        #expect(transport.calls.isEmpty)
    }

    @Test func refreshSkipsWithinSixHoursUnlessForced() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        serverHasGym() // an empty gym is checked against its place, which finds the same gym
        func reads() -> Int { transport.calls.filter { $0 == "publicListings" }.count }
        _ = try await client.refresh(gymId: gym.id, force: false)
        #expect(reads() == 1)
        f.clock.advance(5 * 3_600)
        _ = try await client.refresh(gymId: gym.id, force: false)
        #expect(reads() == 1)
        _ = try await client.refresh(gymId: gym.id, force: true)
        #expect(reads() == 2)
        f.clock.advance(7 * 3_600)
        _ = try await client.refresh(gymId: gym.id, force: false)
        #expect(reads() == 3)
    }

    // MARK: A stale server gym id

    @Test func aKnownIdWithNoListingsIsCheckedAgainstThePlaceAndAnotherIdIsFollowed() async throws {
        defer { f.tearDown() }
        let stale = UUID()
        let gym = try mapsGym(remoteId: stale)
        serverHasGym()
        let there = remote()
        transport.listingsByGym = [stale: [], serverGymId: [there]]
        _ = try await client.refresh(gymId: gym.id, force: true)
        #expect(try gymRecord(gym.id).remoteId == serverGymId)
        #expect(transport.listingsAsked == [stale, serverGymId])
        #expect(try listingRecord(there.id) != nil)
        #expect(try gymRecord(gym.id).catalogRefreshedAt != nil)
    }

    @Test func aKnownIdTheServerNoLongerHasIsClearedAndItsCachedRowsGo() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        let there = remote()
        transport.listings = [there]
        _ = try await client.refresh(gymId: gym.id, force: true)
        transport.listings = []
        transport.gym = nil
        _ = try await client.refresh(gymId: gym.id, force: true)
        #expect(try gymRecord(gym.id).remoteId == nil)
        #expect(try listingRecord(there.id) == nil)
    }

    @Test func theSameIdWithNoListingsStaysAndIsLookedUpOnce() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        serverHasGym()
        _ = try await client.refresh(gymId: gym.id, force: true)
        #expect(try gymRecord(gym.id).remoteId == serverGymId)
        #expect(transport.calls.filter { $0 == "publicGym" }.count == 1)
        #expect(transport.listingsAsked == [serverGymId])
    }

    @Test func aGymFoundJustNowIsNotLookedUpAgain() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        serverHasGym()
        _ = try await client.refresh(gymId: gym.id, force: true)
        #expect(transport.calls.filter { $0 == "publicGym" }.count == 1)
    }

    // MARK: Pictures

    @Test func picturesStillMissingAreWorkedOutFromLocalStateInsideTheSixHours() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        let a = remote(photo: "\(UUID().uuidString.lowercased()).jpg")
        transport.listings = [a]
        let first = try await client.refresh(gymId: gym.id, force: false)
        #expect(first.photosToFetch == [PhotoFetch(listingId: a.id, path: a.photoPath!)])
        let reads = transport.calls.count
        // The app was closed before the download ended.
        f.clock.advance(3_600)
        let again = try await client.refresh(gymId: gym.id, force: false)
        #expect(again.photosToFetch == first.photosToFetch)
        #expect(transport.calls.count == reads, "no server call inside the six hours")
        try listingRecord(a.id)?.photoFile = "got.jpg"
        let done = try await client.refresh(gymId: gym.id, force: false)
        #expect(done.photosToFetch.isEmpty)
    }

    @Test func aRefreshHandsOutAtMostAHundredPicturesAndTheRestComeNext() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        let all = (0..<120).map { _ in remote(photo: "\(UUID().uuidString.lowercased()).jpg") }
        transport.listings = all
        let first = try await client.refresh(gymId: gym.id, force: true)
        #expect(first.photosToFetch.count == 100)
        for fetch in first.photosToFetch { try listingRecord(fetch.listingId)?.photoFile = "\(fetch.listingId).jpg" }
        let next = try await client.refresh(gymId: gym.id, force: false)
        #expect(next.photosToFetch.count == 20)
        #expect(Set(next.photosToFetch.map(\.listingId)).isDisjoint(with: first.photosToFetch.map(\.listingId)))
    }

    @Test func aGymNotOnTheServerStaysLocal() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        transport.gym = nil
        let result = try await client.refresh(gymId: gym.id, force: false)
        #expect(result == .empty)
        let record = try gymRecord(gym.id)
        #expect(record.remoteId == nil)
        #expect(record.catalogRefreshedAt == f.clock.now)
        #expect(transport.calls == ["publicGym"])
    }

    @Test func theItemIdIsRepointedToTheServersItem() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        let own = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", brand: "Hammer"))
        let row = try #require(try listingRecord(own.id))
        row.visibilityRaw = GymVisibility.shared.rawValue
        row.uploadStateRaw = UploadState.uploaded.rawValue
        let serverItem = UUID()
        transport.listings = [remote(id: own.id, item: serverItem, brand: "Hammer", mine: true)]
        _ = try await client.refresh(gymId: gym.id, force: true)
        let after = try #require(try repo.listing(own.id))
        #expect(after.item.id == serverItem)
        #expect(after.item.brand == "Hammer")
        #expect(after.isOwn)
    }

    @Test func aRefreshKeepsTheNameAppleMapsGave() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        serverHasGym()
        _ = try await client.refresh(gymId: gym.id, force: true)
        let kept = try #require(try repo.gym(gym.id))
        #expect(kept.name == "Apple Name")
        #expect(kept.address == "1 Main")
        #expect(kept.latitude == 1)
        #expect(kept.longitude == 2)
        #expect(kept.remoteId == serverGymId)
    }

    @Test func offlineLeavesTheCacheAlone() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        let a = remote()
        transport.listings = [a]
        _ = try await client.refresh(gymId: gym.id, force: true)
        transport.failure = .offline
        transport.listings = []
        let result = try await client.refresh(gymId: gym.id, force: true)
        #expect(result == .empty)
        #expect(try repo.listings(gymId: gym.id).map(\.id) == [a.id])
    }

    @Test func otherFailuresReachTheCaller() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        transport.failure = .rejected("nope")
        await #expect(throws: GymCatalogError.rejected("nope")) {
            _ = try await client.refresh(gymId: gym.id, force: true)
        }
    }

    @Test func itemsMergeTheServersWithMyGymsAndFallBackOffline() async throws {
        defer { f.tearDown() }
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", brand: "Hammer"))
        transport.items = [RemoteItem(id: UUID(), kindId: "cable-stack", brand: "hammer", model: nil, gymCount: 5),
                           RemoteItem(id: UUID(), kindId: "cable-stack", brand: "Life Fitness", model: nil, gymCount: 2),
                           RemoteItem(id: UUID(), kindId: "cable-stack", brand: nil, model: nil, gymCount: 9)]
        let merged = await client.items(kindId: "cable-stack")
        #expect(merged.map(\.item.brand) == ["hammer", "Life Fitness"])
        #expect(merged.map(\.gymCount) == [5, 2])
        transport.failure = .offline
        let offline = await client.items(kindId: "cable-stack")
        #expect(offline.map(\.item.brand) == ["Hammer"])
    }

    /// The add flow stores a picked server model with `upsertItem`, so the items it lists carry the picture too.
    @Test func aServersItemKeepsItsCataloguePhoto() async throws {
        defer { f.tearDown() }
        let listingId = UUID()
        transport.items = [RemoteItem(id: UUID(), kindId: "cable-stack", brand: "Hammer", model: nil, gymCount: 5,
                                      photoPath: "h.jpg", photoListingId: listingId)]
        let item = try #require(await client.items(kindId: "cable-stack").first)
        #expect(item.item.catalogPhotoPath == "h.jpg")
        #expect(item.item.catalogPhotoListingId == listingId)
    }

    // MARK: - Catalogue photos

    private func itemRecord(_ id: UUID) throws -> EquipmentItemRecord? {
        try f.context.fetch(FetchDescriptor<EquipmentItemRecord>(predicate: #Predicate { $0.id == id })).first
    }

    @Test func refreshCachesAnItemsCataloguePhoto() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        let item = UUID(), source = UUID()
        transport.listings = [remote(item: item)]
        transport.items = [RemoteItem(id: item, kindId: "cable-stack", brand: nil, model: nil, gymCount: 1,
                                      photoPath: "p.jpg", photoListingId: source)]
        _ = try await client.refresh(gymId: gym.id, force: true)
        let row = try #require(try itemRecord(item))
        #expect(row.catalogPhotoPath == "p.jpg")
        #expect(row.catalogPhotoListingId == source)
        #expect(row.id == item)
        let value = try #require(try repo.listings(gymId: gym.id).first?.item)
        #expect(value.catalogPhotoPath == "p.jpg")
        #expect(value.catalogPhotoListingId == source)
        #expect(transport.calls == ["publicListings", "publicItems"])
        #expect(try listingRecord(transport.listings[0].id)?.photoFile == nil)
        #expect(try listingRecord(transport.listings[0].id)?.remotePhotoPath == nil)
    }

    @Test func refreshClearsACataloguePhotoTheServerNoLongerReturns() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        let item = UUID()
        transport.listings = [remote(item: item)]
        transport.items = [RemoteItem(id: item, kindId: "cable-stack", brand: nil, model: nil, gymCount: 1,
                                      photoPath: "p.jpg", photoListingId: UUID())]
        _ = try await client.refresh(gymId: gym.id, force: true)
        transport.items = [RemoteItem(id: item, kindId: "cable-stack", brand: nil, model: nil, gymCount: 1)]
        _ = try await client.refresh(gymId: gym.id, force: true)
        let row = try #require(try itemRecord(item))
        #expect(row.catalogPhotoPath == nil)
        #expect(row.catalogPhotoListingId == nil)
    }

    @Test func aFailedItemsCallKeepsTheCachedPhoto() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym(remoteId: serverGymId)
        let item = UUID(), source = UUID()
        transport.listings = [remote(item: item)]
        transport.items = [RemoteItem(id: item, kindId: "cable-stack", brand: nil, model: nil, gymCount: 1,
                                      photoPath: "p.jpg", photoListingId: source)]
        _ = try await client.refresh(gymId: gym.id, force: true)
        transport.failingCalls = ["publicItems"]
        _ = try await client.refresh(gymId: gym.id, force: true)
        let row = try #require(try itemRecord(item))
        #expect(row.catalogPhotoPath == "p.jpg")
        #expect(row.catalogPhotoListingId == source)
    }

    @Test func aGymWithNoPlaceNeverAsksForItems() async throws {
        defer { f.tearDown() }
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        _ = try await client.refresh(gymId: gym.id, force: true)
        #expect(transport.calls.isEmpty)
    }

    @Test func upsertItemStoresTheChosenModelOnce() async throws {
        defer { f.tearDown() }
        let id = UUID(), source = UUID()
        let remoteItem = RemoteItem(id: id, kindId: "cable-stack", brand: "Hammer", model: "MD", gymCount: 4,
                                    photoPath: "p.jpg", photoListingId: source)
        let first = try client.upsertItem(remoteItem)
        let second = try client.upsertItem(remoteItem)
        #expect(first == second)
        #expect(first.id == id)
        #expect(first.brand == "Hammer")
        #expect(first.model == "MD")
        #expect(first.catalogPhotoPath == "p.jpg")
        #expect(try f.context.fetch(FetchDescriptor<EquipmentItemRecord>(predicate: #Predicate { $0.id == id })).count == 1)
    }
}
