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
    static let lifeFitnessItemId = UUID(uuidString: "00000000-0000-4000-8000-0000000000C1")!

    static let latPulldown = listing(id: latPulldownId, itemId: lifeFitnessItemId, kind: "lat-pulldown",
                                     brand: "Life Fitness", model: "Pulldown", photo: "lat-pulldown.jpg",
                                     loads: .stack(maxKg: 90, stepKg: 5), confirms: 3)
    static let cable = listing(id: cableId, itemId: GymRepository.genericItemId(forKind: "cable-station"),
                               kind: "cable-station", brand: nil, model: nil, photo: nil, loads: ListingLoads.none,
                               confirms: 2)
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

struct FakeGymCatalogTransport: GymCatalogTransport {
    func publicGym(mapsPlaceId: String) async throws -> RemoteGym? {
        mapsPlaceId == FakeGymCatalog.placeId
            ? RemoteGym(id: FakeGymCatalog.serverGymId, name: "Iron Works Gym", address: nil, latitude: nil,
                        longitude: nil, mapsPlaceId: mapsPlaceId)
            : nil
    }

    func publicListings(gymId: UUID) async throws -> PublicListings {
        PublicListings(listings: gymId == FakeGymCatalog.serverGymId
            ? [FakeGymCatalog.latPulldown, FakeGymCatalog.cable, FakeGymCatalog.newerApp] : [])
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
