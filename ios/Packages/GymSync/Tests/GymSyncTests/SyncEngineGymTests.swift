import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymSync

final class FakePhotoFiles: GymPhotoFiles, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]
    private var gone: [String] = []

    init(_ files: [String: Data] = [:]) { self.files = files }

    var stored: [String: Data] { lock.withLock { files } }
    var deleted: [String] { lock.withLock { gone } }
    func data(file: String) -> Data? { lock.withLock { files[file] } }
    func save(_ jpeg: Data, file: String) throws { lock.withLock { files[file] = jpeg } }
    func delete(file: String) throws { lock.withLock { files[file] = nil; gone.append(file) } }
}

@MainActor
@Suite struct SyncEngineGymTests {
    let f: EngineFixture
    let photos = FakePhotoFiles(["mine.jpg": Data("jpeg".utf8)])
    let engine: SyncEngine
    init() throws {
        f = try EngineFixture()
        engine = SyncEngine(store: f.store, transport: f.server, photos: photos, now: { [clock = f.clock] in clock.now })
    }

    private var gyms: GymRepository {
        GymRepository(context: f.container.mainContext, now: { [clock = f.clock] in clock.now })
    }

    private func syncedListing(brand: String? = nil, photo: String? = nil) throws -> (Gym, GymListing) {
        let gym = try gyms.addPrivateGym(name: "Home", address: nil)
        let listing = try gyms.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", brand: brand,
                                                     loads: .stack(maxKg: 90, stepKg: 5), photoFile: photo))
        try gyms.makeSynced(listing: listing.id)
        return (gym, listing)
    }

    private func record(_ id: UUID) throws -> GymListingRecord? {
        try f.container.mainContext.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first
    }

    @Test func pushesGymsThenListingsBeforeWorkoutsAndPullsInTheSameOrder() async throws {
        defer { f.tearDown() }
        _ = try syncedListing()
        try f.workouts.save(workout(name: "Push", at: f.clock.now))
        await engine.sync()
        let log = await f.server.callLog
        let order = ["push:gyms", "push:gymListings", "push:workout", "pull:gyms", "pull:gymListings", "pull:workouts"]
        #expect(log.filter(order.contains) == order)
        #expect(try f.store.dirtyGyms().isEmpty)
        #expect(try f.store.dirtyGymListings().isEmpty)
    }

    @Test func aListingPhotoUploadsToThePrivateBucketUnderANewNameBeforeTheRowIsSent() async throws {
        defer { f.tearDown() }
        let (_, listing) = try syncedListing(photo: "mine.jpg")
        await engine.sync()
        let names = await f.server.privatePhotos.keys
        let name = try #require(names.first)
        let stem = try #require(name.split(separator: ".").first.map(String.init))
        #expect(names.count == 1 && name.hasSuffix(".jpg") && UUID(uuidString: stem) != nil)
        #expect(stem == stem.lowercased() && !name.contains("/"))
        #expect(await f.server.gymListings[listing.id]?.photoPath == name)
        #expect(try record(listing.id)?.remotePhotoPath == name)
    }

    @Test func aFailedUploadLeavesTheRowDirtyAndTheRestOfTheRoundGoesOn() async throws {
        defer { f.tearDown() }
        let (_, listing) = try syncedListing(photo: "mine.jpg")
        try f.routines.upsert(Routine(name: "Push", exercises: []))
        await f.server.setFailUploads(true)
        await engine.sync()
        #expect(try f.store.dirtyGymListings().map(\.value.id) == [listing.id])
        #expect(await f.server.gymListings.isEmpty)
        #expect(await f.server.routines.count == 1)
        #expect(f.store.syncFailures().isEmpty)

        await f.server.setFailUploads(false)
        await engine.sync()
        #expect(try f.store.dirtyGymListings().isEmpty)
        #expect(await f.server.gymListings[listing.id]?.photoPath != nil)
    }

    @Test func aBrandedListingSendsTheGenericItemAndComesBackWithItsBrand() async throws {
        defer { f.tearDown() }
        let (_, listing) = try syncedListing(brand: "Hammer")
        await engine.sync()
        let sent = try #require(await f.server.gymListings[listing.id])
        #expect(sent.brand == "Hammer")

        try f.store.resetAll() // a fresh install of the same account
        await engine.sync()
        let back = try #require(try gyms.listings(gymId: sent.gymId).first)
        #expect(back.id == listing.id)
        #expect(back.item.brand == "Hammer")
        #expect(back.item.kindId == "cable-stack")
        #expect(back.loads == .stack(maxKg: 90, stepKg: 5))
    }

    @Test func aPulledListingWithAPhotoDownloadsItAndAFailedDownloadIsRetriedAtTheNextPull() async throws {
        defer { f.tearDown() }
        let gymId = UUID(), listingId = UUID()
        let at = f.clock.now
        try await f.server.seed(gym: GymDTO(SyncRow(value: SyncedGym(id: gymId, name: "Away", address: nil,
                                                                     latitude: nil, longitude: nil),
                                                    clientUpdatedAt: at)))
        let value = SyncedListing(id: listingId, gymId: gymId, kindId: "cable-stack", brand: nil, model: nil,
                                  loads: .none, quantity: 1, notes: nil, photoFile: nil, remotePhotoPath: "far.jpg")
        try await f.server.seed(gymListing: GymListingDTO(SyncRow(value: value, clientUpdatedAt: at)))
        await f.server.seed(privatePhoto: Data("far".utf8), name: "far.jpg")
        await f.server.setFailDownloads(true)

        await engine.sync()
        #expect(engine.status == .idle)
        #expect(try record(listingId)?.photoFile == nil)

        await f.server.setFailDownloads(false)
        await engine.sync()
        let file = try #require(try record(listingId)?.photoFile)
        #expect(photos.stored[file] == Data("far".utf8))
    }

    @Test func nothingMarkedThisPhoneOnlyIsPushed() async throws {
        defer { f.tearDown() }
        let gym = try gyms.addPrivateGym(name: "Device", address: nil)
        try gyms.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        await engine.sync()
        #expect(await f.server.gyms.isEmpty)
        #expect(await f.server.gymListings.isEmpty)
    }
}

@Suite struct GymDTOTests {
    private let t0 = SyncDate.parse("2026-10-30T12:00:00.123456Z")!

    @Test func aListingEncodesPrivateTextSeparatelyAndNeverTheKind() throws {
        let value = SyncedListing(id: UUID(), gymId: UUID(), kindId: "cable-stack", brand: "Hammer", model: "X1",
                                  loads: .stack(maxKg: 90, stepKg: 5), quantity: 2, notes: "n", photoFile: "a.jpg",
                                  remotePhotoPath: "ABC.jpg")
        let json = try #require(try JSONSerialization.jsonObject(
            with: SyncJSON.encoder.encode(GymListingDTO(SyncRow(value: value, clientUpdatedAt: t0)))) as? [String: Any])
        #expect(json["visibility"] as? String == "private")
        #expect(json["private_brand"] as? String == "Hammer")
        #expect(json["private_model"] as? String == "X1")
        #expect(json["item_id"] as? String == GymRepository.genericItemId(forKind: "cable-stack").uuidString)
        #expect(json["photo_path"] as? String == "abc.jpg")
        #expect(json["kind_id"] == nil && json["updated_at"] == nil && json["owner_id"] == nil)
        #expect(json["client_updated_at"] as? String == "2026-10-30T12:00:00.123456Z")
    }

    @Test func aPulledListingReadsItsKindFromTheEmbeddedItemAndToleratesUnknownLoads() throws {
        let body = #"{"id":"\#(UUID().uuidString)","gym_id":"\#(UUID().uuidString)","item_id":"\#(UUID().uuidString)","#
            + #""photo_path":null,"loads":{"type":"hologram"},"quantity":1,"notes":null,"private_brand":"B","#
            + #""private_model":null,"client_updated_at":"2026-10-30T12:00:00Z","deleted_at":null,"#
            + #""updated_at":"2026-10-30T12:00:01Z","equipment_items":{"kind_id":"cable-stack"}}"#
        let dto = try SyncJSON.decoder.decode(GymListingDTO.self, from: Data(body.utf8))
        let row = try #require(dto.toDomain())
        #expect(row.value.kindId == "cable-stack" && row.value.brand == "B" && row.value.loads == ListingLoads.none)
    }

    @Test func aGymEncodesAsPrivate() throws {
        let row = SyncRow(value: SyncedGym(id: UUID(), name: "Home", address: nil, latitude: nil, longitude: nil),
                          clientUpdatedAt: t0)
        let json = try #require(try JSONSerialization.jsonObject(
            with: SyncJSON.encoder.encode(GymDTO(row))) as? [String: Any])
        #expect(json["visibility"] as? String == "private")
        #expect(json["owner_id"] == nil && json["maps_place_id"] == nil)
    }
}
