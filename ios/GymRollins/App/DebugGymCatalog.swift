#if DEBUG
import Foundation
import GymCore
import GymData
import SwiftData

/// DEBUG/UI-test only (`-fakeGymCatalog`): the fixed shared listings of "Iron Works Gym" (Maps id `fake-iron-works`,
/// the one `-fakeGymPlaces` offers), served with no network. Writes succeed at once; a signed-out phone never gets
/// that far, which is what the UI tests check.
enum FakeGymCatalog {
    static let placeId = "fake-iron-works"
    static let serverGymId = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    static let latPulldownId = UUID(uuidString: "00000000-0000-4000-8000-0000000000B1")!
    static let cableId = UUID(uuidString: "00000000-0000-4000-8000-0000000000B2")!
    static let newerAppId = UUID(uuidString: "00000000-0000-4000-8000-0000000000B3")!
    static let rowId = UUID(uuidString: "00000000-0000-4000-8000-0000000000B4")!
    static let lifeFitnessItemId = UUID(uuidString: "00000000-0000-4000-8000-0000000000C1")!

    static let latPulldown = listing(id: latPulldownId, itemId: lifeFitnessItemId, kind: "lat-pulldown",
                                     brand: "Life Fitness", model: "Pulldown", photo: "lat-pulldown.jpg",
                                     loads: .stack(maxKg: 90, stepKg: 5), confirms: 3)
    static let cable = listing(id: cableId, itemId: GymRepository.genericItemId(forKind: "cable-station"),
                               kind: "cable-station", brand: nil, model: nil, photo: nil, loads: ListingLoads.none,
                               confirms: 2)
    /// What `-fakeGymCatalogGrows` adds from the second read on.
    static let row = listing(id: rowId, itemId: GymRepository.genericItemId(forKind: "seated-row-machine"),
                             kind: "seated-row-machine", brand: nil, model: nil, photo: nil,
                             loads: .stack(maxKg: 90, stepKg: 5), confirms: 1)
    /// Loads this app can't read: it comes back unsupported.
    static let newerApp = listing(id: newerAppId, itemId: GymRepository.genericItemId(forKind: "leg-press"),
                                  kind: "leg-press", brand: nil, model: nil, photo: nil, loads: nil, confirms: 1)

    static func listing(id: UUID, itemId: UUID, kind: String, brand: String?, model: String?, photo: String?,
                        loads: ListingLoads?, confirms: Int) -> RemoteListing {
        RemoteListing(id: id, gymId: serverGymId, itemId: itemId, kindId: kind, brand: brand, model: model,
                      photoPath: photo, loads: loads, quantity: 1, notes: nil, status: "active",
                      confirmCount: confirms, isMine: false, confirmedByMe: false)
    }
}

/// What `-fakeGymAdmin` shows: a flagged listing with a photo, an unflagged one with a single report, a flagged gym, and
/// a listing removed earlier whose photo is still to delete. The first is restored by the UI test, the others removed.
enum FakeModeration {
    static let pulldownId = UUID(uuidString: "00000000-0000-4000-8000-0000000000D1")!
    static let cableId = UUID(uuidString: "00000000-0000-4000-8000-0000000000D2")!
    static let gymId = UUID(uuidString: "00000000-0000-4000-8000-0000000000D3")!
    /// Removed by an admin earlier, its photo never deleted.
    static let staleId = UUID(uuidString: "00000000-0000-4000-8000-0000000000D4")!

    static let queue = [
        ModerationEntry(targetType: .listing, targetId: pulldownId, title: "Life Fitness Pulldown",
                        photoPath: "5b0f1c1e-5a37-4b8e-9d1f-0a3c6e7f2b11.jpg", reportCount: 3,
                        reasons: [.init(reason: "person-in-photo", count: 2), .init(reason: "spam", count: 1)],
                        notes: ["There is a face in it", "Looks like an advert"], status: .flagged,
                        listingNotes: "Bring your own towel"),
        ModerationEntry(targetType: .listing, targetId: cableId, title: "Cable Station", photoPath: nil,
                        reportCount: 1, reasons: [.init(reason: "wrong-info", count: 1)], notes: [], status: .active),
        ModerationEntry(targetType: .gym, targetId: gymId, title: "Iron Works Annex", photoPath: nil, reportCount: 3,
                        reasons: [.init(reason: "duplicate", count: 3)], notes: ["Same place as Iron Works"],
                        status: .flagged, address: "14 Side Street"),
        ModerationEntry(targetType: .listing, targetId: staleId, title: "Old Rack",
                        photoPath: "7c1d9a52-3e0b-4f3a-8c52-9a1e4d6b7f20.jpg", reportCount: 0, reasons: [], notes: [],
                        status: .removed),
    ]
}

final class FakeGymCatalogTransport: GymCatalogTransport, @unchecked Sendable {
    private let admin: Bool
    private let grows: Bool
    private let lock = NSLock()
    private var reads = 0
    private var flagged: [ModerationEntry]
    /// People this signed-in test user has blocked: two to start, so "Unblock everyone" has something to clear.
    private var blocked = 2

    init(admin: Bool = false, grows: Bool = false) {
        self.admin = admin
        self.grows = grows
        flagged = admin ? FakeModeration.queue : []
    }

    func publicGym(mapsPlaceId: String) async throws -> RemoteGym? {
        mapsPlaceId == FakeGymCatalog.placeId
            ? RemoteGym(id: FakeGymCatalog.serverGymId, name: "Iron Works Gym", address: nil, latitude: nil,
                        longitude: nil, mapsPlaceId: mapsPlaceId)
            : nil
    }

    func publicListings(gymId: UUID) async throws -> PublicListings {
        let read = lock.withLock { () -> Int in reads += 1; return reads }
        guard gymId == FakeGymCatalog.serverGymId else { return PublicListings(listings: []) }
        let fixed = [FakeGymCatalog.latPulldown, FakeGymCatalog.cable, FakeGymCatalog.newerApp]
        return PublicListings(listings: grows && read >= 2 ? fixed + [FakeGymCatalog.row] : fixed)
    }

    /// The flat bench has a picture another gym took; the pulldown's model is listed at four gyms.
    func publicItems(kindId: String) async throws -> [RemoteItem] {
        switch kindId {
        case "flat-bench":
            [RemoteItem(id: GymRepository.genericItemId(forKind: "flat-bench"), kindId: kindId, brand: nil,
                        model: nil, gymCount: 4, photoPath: "flat-bench.jpg", photoListingId: UUID())]
        case "lat-pulldown":
            [RemoteItem(id: FakeGymCatalog.lifeFitnessItemId, kindId: kindId, brand: "Life Fitness",
                        model: "Pulldown", gymCount: 4, photoPath: "lat-pulldown.jpg",
                        photoListingId: FakeGymCatalog.latPulldownId)]
        default: []
        }
    }

    func findOrCreateGym(mapsPlaceId: String, name: String, address: String?, latitude: Double?,
                         longitude: Double?) async throws -> UUID { FakeGymCatalog.serverGymId }
    func share(_ request: ShareRequest) async throws -> ShareResult { .created(request.listingId) }
    func confirm(listingId: UUID) async throws -> Int { 4 }
    func uploadSharedPhoto(_ data: Data, name: String) async throws -> String { name }
    func deleteSharedPhoto(path: String) async throws {}
    func deleteAllPhotos() async throws {}
    func detachAllPhotos() async throws {}
    func report(targetType: GymTargetType, targetId: UUID, reason: ReportReason, note: String?) async throws {}
    func blockAuthor(targetType: GymTargetType, targetId: UUID) async throws { lock.withLock { blocked += 1 } }
    func unblockAll() async throws -> Int {
        lock.withLock {
            defer { blocked = 0 }
            return blocked
        }
    }
    func isAdmin() async throws -> Bool { admin }
    func moderationQueue() async throws -> [ModerationEntry] { lock.withLock { flagged } }
    func moderate(targetType: GymTargetType, targetId: UUID, action: ModerationAction) async throws -> String? {
        let decided = lock.withLock { () -> ModerationEntry? in
            let found = flagged.first { $0.targetId == targetId }
            flagged.removeAll { $0.targetId == targetId }
            return found
        }
        return action == .remove ? decided?.photoPath : nil
    }
    func moderationPhotoDeleted(path: String) async throws {}
    func publicPhotoURL(path: String) -> URL? { URL(string: "https://photos.uitest.invalid/gym-photos/\(path)") }
}

/// `-fakeGymCatalog`: "Iron Works Gym" as the current gym, with what the sharing screens need on the phone already: a
/// flat bench that only this phone has, a barbell whose share failed, and a cable station waiting for the user to say
/// whether the gym's own is the same.
@MainActor
enum DebugSharedGymSeed {
    @discardableResult
    static func apply(context: ModelContext, now: Date) throws -> Gym {
        let gyms = GymRepository(context: context, now: { now })
        if let existing = try gyms.gyms().first(where: { $0.mapsPlaceId == FakeGymCatalog.placeId }) { return existing }
        let gym = try gyms.addMapsGym(placeId: FakeGymCatalog.placeId, name: "Iron Works Gym", address: "12 Main St",
                                      latitude: 40.0, longitude: -74.0)
        try gyms.addListing(NewListing(gymId: gym.id, kindId: "flat-bench"))
        let failed = try gyms.addListing(NewListing(gymId: gym.id, kindId: "barbell"))
        let waiting = try gyms.addListing(NewListing(gymId: gym.id, kindId: "cable-station"))
        for row in try context.fetch(FetchDescriptor<GymListingRecord>()) {
            if row.id == failed.id {
                row.uploadStateRaw = UploadState.failed.rawValue
                row.uploadError = "Couldn't share this one. Try again later."
            } else if row.id == waiting.id {
                row.visibilityRaw = GymVisibility.shared.rawValue
                row.uploadStateRaw = UploadState.waitingForChoice.rawValue
                row.duplicatesData = try JSONEncoder().encode([FakeGymCatalog.cable])
            }
        }
        try context.save()
        return gym
    }
}
#endif
