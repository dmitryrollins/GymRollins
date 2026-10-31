import Foundation
import GymCore
import GymData

/// A scripted server for the app's catalogue tests. Every call is recorded by name.
final class StubCatalogTransport: GymCatalogTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var gym: RemoteGym?
    var listings: [RemoteListing] = []
    var items: [RemoteItem] = []
    var failure: GymCatalogError?

    var calls: [String] { lock.withLock { _calls } }

    private func record(_ name: String) throws {
        try lock.withLock {
            _calls.append(name)
            if let failure { throw failure }
        }
    }

    func publicGym(mapsPlaceId: String) async throws -> RemoteGym? { try record("publicGym"); return gym }
    func publicListings(gymId: UUID) async throws -> PublicListings {
        try record("publicListings")
        return PublicListings(listings: listings)
    }
    func publicItems(kindId: String) async throws -> [RemoteItem] {
        try record("publicItems")
        return items.filter { $0.kindId == kindId }
    }
    func findOrCreateGym(mapsPlaceId: String, name: String, address: String?, latitude: Double?,
                         longitude: Double?) async throws -> UUID {
        try record("findOrCreateGym")
        return gym?.id ?? UUID()
    }
    func share(_ request: ShareRequest) async throws -> ShareResult {
        try record("share")
        return .created(request.listingId)
    }
    func confirm(listingId: UUID) async throws -> Int { try record("confirm"); return 1 }
    func uploadSharedPhoto(_ data: Data, name: String) async throws -> String { try record("upload"); return name }
    func publicPhotoURL(path: String) -> URL? { URL(string: "https://photos.uitest.invalid/gym-photos/\(path)") }
}
