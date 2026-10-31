import Foundation
import GymCore
@testable import GymData

/// Scripted server for the catalogue tests. Every call is recorded by name.
final class FakeGymCatalogTransport: GymCatalogTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _gym: RemoteGym?
    private var _listings: [RemoteListing] = []
    private var _items: [RemoteItem] = []
    private var _failure: GymCatalogError?

    var calls: [String] { lock.withLock { _calls } }
    var gym: RemoteGym? { get { lock.withLock { _gym } } set { lock.withLock { _gym = newValue } } }
    var listings: [RemoteListing] { get { lock.withLock { _listings } } set { lock.withLock { _listings = newValue } } }
    var items: [RemoteItem] { get { lock.withLock { _items } } set { lock.withLock { _items = newValue } } }
    var failure: GymCatalogError? { get { lock.withLock { _failure } } set { lock.withLock { _failure = newValue } } }

    private func record(_ name: String) throws {
        try lock.withLock {
            _calls.append(name)
            if let _failure { throw _failure }
        }
    }

    func publicGym(mapsPlaceId: String) async throws -> RemoteGym? { try record("publicGym"); return gym }
    func publicListings(gymId: UUID) async throws -> [RemoteListing] { try record("publicListings"); return listings }
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
    func uploadSharedPhoto(_ data: Data, name: String) async throws -> String {
        try record("uploadSharedPhoto")
        return name
    }
    func publicPhotoURL(path: String) -> URL? { URL(string: "https://example.test/gym-photos/\(path)") }
}
