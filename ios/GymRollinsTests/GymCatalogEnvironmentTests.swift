import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymRollins

/// The environment's side of the shared catalogue: refreshing a Maps gym, the pictures it downloads, and the rules
/// that keep a private gym and a signed-out user off the server.
@MainActor
@Suite struct GymCatalogEnvironmentTests {
    private let serverGym = UUID()
    private let jpeg = GymPhotoFixture.jpegData()

    private func rig(download: @escaping @Sendable (URL, Int) async throws -> Data = { _, _ in Data() })
        throws -> (GymTestRig, StubCatalogTransport) {
        let rig = try GymTestRig.make()
        let stub = StubCatalogTransport()
        stub.gym = RemoteGym(id: serverGym, name: "Server", address: nil, latitude: nil, longitude: nil,
                             mapsPlaceId: "P1")
        rig.env.gymSharing = GymSharing(
            repository: rig.env.gyms, transport: stub, knownKinds: ["lat-pulldown", "flat-bench"],
            photos: GymPhotoCache(store: rig.photos, download: download), photoData: { rig.photos.data(file: $0) },
            now: rig.env.now)
        return (rig, stub)
    }

    private func mapsGym(_ rig: GymTestRig) throws -> Gym {
        try rig.env.gyms.addMapsGym(placeId: "P1", name: "Iron", address: nil, latitude: 1, longitude: 2)
    }

    private func remote(photo: String? = nil, kind: String = "lat-pulldown") -> RemoteListing {
        RemoteListing(id: UUID(), gymId: serverGym, itemId: UUID(), kindId: kind, brand: nil, model: nil,
                      photoPath: photo, loads: .stack(maxKg: 90, stepKg: 5), quantity: 1, notes: nil,
                      status: "active", confirmCount: 2, isMine: false, confirmedByMe: false)
    }

    private func record(_ id: UUID, _ rig: GymTestRig) throws -> GymListingRecord {
        try #require(try rig.env.container.mainContext.fetch(
            FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first)
    }

    @Test func aMapsGymRefreshDownloadsTheOthersPhotos() async throws {
        let data = jpeg
        let (rig, stub) = try rig { _, _ in data }
        let gym = try mapsGym(rig)
        let entry = remote(photo: "x.jpg")
        stub.listings = [entry]
        await rig.env.gymCatalogRefresh(gymId: gym.id, force: false)
        let row = try record(entry.id, rig)
        let file = try #require(row.photoFile)
        #expect(FileManager.default.fileExists(atPath: rig.photos.url(file).path()))
        #expect(rig.photoCount() == 2, "the picture and its thumbnail")
        #expect(row.remotePhotoPath == "x.jpg")
    }

    @Test func aDownloadThatIsNotAJPEGLeavesTheListingWithoutAPhoto() async throws {
        let (rig, stub) = try rig { _, _ in Data([0x89, 0x50, 0x4E, 0x47]) }
        let gym = try mapsGym(rig)
        let entry = remote(photo: "x.jpg")
        stub.listings = [entry]
        await rig.env.gymCatalogRefresh(gymId: gym.id, force: false)
        #expect(try record(entry.id, rig).photoFile == nil)
        #expect(rig.photoCount() == 0)
    }

    @Test func aPrivateGymMakesNoServerCalls() async throws {
        let (rig, stub) = try rig()
        let gym = try rig.gym("Home", ["flat-bench": .none])
        await rig.env.gymCatalogRefresh(gymId: gym.id, force: true)
        let listing = try #require(try rig.env.gyms.listings(gymId: gym.id).first)
        #expect(throws: (any Error).self) { try rig.env.shareListing(listing.id) }
        #expect(stub.calls.isEmpty)
    }

    @Test func offlineStaysSilentAndKeepsTheCachedRows() async throws {
        let (rig, stub) = try rig()
        let gym = try mapsGym(rig)
        stub.listings = [remote()]
        await rig.env.gymCatalogRefresh(gymId: gym.id, force: false)
        let revision = rig.env.gymRevision
        stub.failure = .offline
        await rig.env.gymCatalogRefresh(gymId: gym.id, force: true)
        #expect(try rig.env.gyms.listings(gymId: gym.id).count == 1)
        #expect(rig.env.gymRevision == revision, "nothing changed, so nothing reloads")
    }

    @Test func aFreshCacheIsNotAskedAgainUntilForced() async throws {
        let (rig, stub) = try rig()
        let gym = try mapsGym(rig)
        await rig.env.gymCatalogRefresh(gymId: gym.id, force: false)
        let first = stub.calls.count
        await rig.env.gymCatalogRefresh(gymId: gym.id, force: false)
        #expect(stub.calls.count == first)
        await rig.env.gymCatalogRefresh(gymId: gym.id, force: true)
        #expect(stub.calls.count > first)
    }

    @Test func aRefreshThatChangedRowsReloadsTheScreens() async throws {
        let (rig, stub) = try rig()
        let gym = try mapsGym(rig)
        stub.listings = [remote()]
        let before = rig.env.gymRevision
        await rig.env.gymCatalogRefresh(gymId: gym.id, force: false)
        #expect(rig.env.gymRevision > before)
    }

    /// Decision 14: the picture borrowed from the catalogue is display only.
    @Test func aBorrowedPhotoNeverBecomesTheListingsOwn() async throws {
        let data = jpeg
        let counter = DownloadCount()
        let (rig, stub) = try rig { _, _ in
            counter.bump()
            return data
        }
        let gym = try mapsGym(rig)
        let own = try rig.env.gyms.addListing(NewListing(gymId: gym.id, kindId: "flat-bench"))
        stub.items = [RemoteItem(id: own.item.id, kindId: "flat-bench", brand: nil, model: nil, gymCount: 3,
                                 photoPath: "bench.jpg", photoListingId: UUID())]
        await rig.env.gymCatalogRefresh(gymId: gym.id, force: true)
        let row = try record(own.id, rig)
        #expect(row.photoFile == nil && row.remotePhotoPath == nil)
        #expect(counter.value == 0, "nothing was downloaded for it")
        #expect(try rig.env.gyms.listing(own.id)?.item.catalogPhotoPath == "bench.jpg")
        #expect(rig.photoCount() == 0)
    }

    @Test func aSignedOutShareOrConfirmQueuesNothing() async throws {
        let (rig, stub) = try rig()
        let gym = try mapsGym(rig)
        let own = try rig.env.gyms.addListing(NewListing(gymId: gym.id, kindId: "flat-bench"))
        #expect(rig.env.sharingUserId == nil)
        #expect(throws: GymCatalogError.signedOut) { try rig.env.shareListing(own.id) }
        #expect(throws: GymCatalogError.signedOut) { try rig.env.confirmListing(own.id) }
        #expect(rig.env.gymSharing.outbox.pendingCount == 0)
        #expect(try rig.env.gyms.listing(own.id)?.visibility == .device)
        #expect(stub.calls.isEmpty)
    }

    @Test func theFakeCatalogFlagIsParsed() {
        #expect(LaunchOptions(arguments: ["-uiTesting", "-fakeGymCatalog"]).fakeGymCatalog)
        #expect(!LaunchOptions(arguments: ["-uiTesting"]).fakeGymCatalog)
    }
}

private final class DownloadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}
