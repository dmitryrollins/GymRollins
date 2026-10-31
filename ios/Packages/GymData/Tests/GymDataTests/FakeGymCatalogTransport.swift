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
    private var _failingCalls: Set<String> = []
    private var _shareScript: [Result<ShareResult, GymCatalogError>] = []
    private var _requests: [ShareRequest] = []
    private var _uploads: [String] = []
    private var _confirmed: [UUID] = []
    private var _confirmResult = 1

    var calls: [String] { lock.withLock { _calls } }
    var gym: RemoteGym? { get { lock.withLock { _gym } } set { lock.withLock { _gym = newValue } } }
    var listings: [RemoteListing] { get { lock.withLock { _listings } } set { lock.withLock { _listings = newValue } } }
    var items: [RemoteItem] { get { lock.withLock { _items } } set { lock.withLock { _items = newValue } } }
    /// Calls that fail with `.offline` while the rest work.
    var failingCalls: Set<String> { get { lock.withLock { _failingCalls } } set { lock.withLock { _failingCalls = newValue } } }
    /// Answers for the next `share` calls, used up in order; after that every share creates the listing.
    var shareScript: [Result<ShareResult, GymCatalogError>] {
        get { lock.withLock { _shareScript } } set { lock.withLock { _shareScript = newValue } }
    }
    var requests: [ShareRequest] { lock.withLock { _requests } }
    var uploads: [String] { lock.withLock { _uploads } }
    var confirmed: [UUID] { lock.withLock { _confirmed } }
    var confirmResult: Int { get { lock.withLock { _confirmResult } } set { lock.withLock { _confirmResult = newValue } } }
    var failure: GymCatalogError? { get { lock.withLock { _failure } } set { lock.withLock { _failure = newValue } } }

    private func record(_ name: String) throws {
        try lock.withLock {
            _calls.append(name)
            if let _failure { throw _failure }
            if _failingCalls.contains(name) { throw GymCatalogError.offline }
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
        let scripted: Result<ShareResult, GymCatalogError>? = lock.withLock {
            _requests.append(request)
            return _shareScript.isEmpty ? nil : _shareScript.removeFirst()
        }
        return try scripted?.get() ?? .created(request.listingId)
    }
    func confirm(listingId: UUID) async throws -> Int {
        try record("confirm")
        return lock.withLock { _confirmed.append(listingId); return _confirmResult }
    }
    func uploadSharedPhoto(_ data: Data, name: String) async throws -> String {
        try record("uploadSharedPhoto")
        lock.withLock { _uploads.append(name) }
        return name
    }
    func publicPhotoURL(path: String) -> URL? { URL(string: "https://example.test/gym-photos/\(path)") }
}
