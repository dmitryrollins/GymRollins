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
    private var _skipped = 0
    private var _byGym: [UUID: [RemoteListing]] = [:]
    private var _unshareable: Set<UUID> = []
    private var _listingsAsked: [UUID] = []
    private var _capped = false
    private var _failure: GymCatalogError?
    private var _failingCalls: Set<String> = []
    private var _shareScript: [Result<ShareResult, GymCatalogError>] = []
    private var _requests: [ShareRequest] = []
    private var _uploads: [String] = []
    private var _confirmed: [UUID] = []
    private var _confirmResult = 1
    private var _serverShares: [UUID: ShareRequest] = [:]
    private var _shareOrder: [UUID] = []
    private var _loseNextShareResponse = false
    private var _confirmCounts: [UUID: Int] = [:]
    private var _confirmers: Set<UUID> = []
    private var _deleted: [String] = []
    private var _reports: [ReportCall] = []
    private var _blocks: [BlockCall] = []
    private var _unblocks = 0
    private var _reportScript: [GymCatalogError?] = []
    private var _unblockResult = 0
    private var _ownTargets: Set<UUID> = []
    private var _stalledCalls: Set<String> = []
    private var _reportAnswers: [UUID: String] = [:]

    struct ReportCall: Equatable {
        let type: GymTargetType, id: UUID, reason: ReportReason, note: String?
    }
    struct BlockCall: Equatable { let type: GymTargetType, id: UUID }

    var calls: [String] { lock.withLock { _calls } }
    var reports: [ReportCall] { lock.withLock { _reports } }
    var blocks: [BlockCall] { lock.withLock { _blocks } }
    var unblocks: Int { lock.withLock { _unblocks } }
    /// Answers for the next `report` calls, used up in order: an error refuses it, nil lets it through.
    var reportScript: [GymCatalogError?] { get { lock.withLock { _reportScript } } set { lock.withLock { _reportScript = newValue } } }
    /// Targets the caller wrote: the server answers `own` for a report of one and files nothing, as the real function does.
    var ownTargets: Set<UUID> { get { lock.withLock { _ownTargets } } set { lock.withLock { _ownTargets = newValue } } }
    /// What the server said to each reported target: `reported` or `own`.
    var reportAnswers: [UUID: String] { lock.withLock { _reportAnswers } }
    /// Calls that never answer on their own: they wait until the task is cancelled, as a request on a dead connection does.
    var stalledCalls: Set<String> { get { lock.withLock { _stalledCalls } } set { lock.withLock { _stalledCalls = newValue } } }
    var unblockResult: Int { get { lock.withLock { _unblockResult } } set { lock.withLock { _unblockResult = newValue } } }
    var gym: RemoteGym? { get { lock.withLock { _gym } } set { lock.withLock { _gym = newValue } } }
    var listings: [RemoteListing] { get { lock.withLock { _listings } } set { lock.withLock { _listings = newValue } } }
    /// Rows the server "sent" that no version could read, and a read that hit its cap.
    var skipped: Int { get { lock.withLock { _skipped } } set { lock.withLock { _skipped = newValue } } }
    var capped: Bool { get { lock.withLock { _capped } } set { lock.withLock { _capped = newValue } } }
    /// Listings per server gym; a gym with no entry here gets `listings`.
    var listingsByGym: [UUID: [RemoteListing]] { get { lock.withLock { _byGym } } set { lock.withLock { _byGym = newValue } } }
    /// Server gyms that refuse a share with `gym_not_shareable`.
    var unshareableGyms: Set<UUID> { get { lock.withLock { _unshareable } } set { lock.withLock { _unshareable = newValue } } }
    /// The gyms `publicListings` was asked about, in order.
    var listingsAsked: [UUID] { lock.withLock { _listingsAsked } }
    var items: [RemoteItem] { get { lock.withLock { _items } } set { lock.withLock { _items = newValue } } }
    /// Calls that fail with `.offline` while the rest work.
    var failingCalls: Set<String> { get { lock.withLock { _failingCalls } } set { lock.withLock { _failingCalls = newValue } } }
    /// Answers for the next `share` calls, used up in order; after that every share creates the listing.
    var shareScript: [Result<ShareResult, GymCatalogError>] {
        get { lock.withLock { _shareScript } } set { lock.withLock { _shareScript = newValue } }
    }
    var requests: [ShareRequest] { lock.withLock { _requests } }
    var uploads: [String] { lock.withLock { _uploads } }
    /// The rows the fake "server" holds, one per listing id in the order they arrived, as the real function does.
    var serverShares: [ShareRequest] { lock.withLock { _shareOrder.compactMap { _serverShares[$0] } } }
    /// The next share is stored and then fails as offline, as when the answer is lost on the way back.
    var loseNextShareResponse: Bool {
        get { lock.withLock { _loseNextShareResponse } } set { lock.withLock { _loseNextShareResponse = newValue } }
    }
    /// Makes `confirm` count like the server: a listing with a count goes up by one for the first confirm only.
    func setConfirmCount(_ count: Int, for listingId: UUID) { lock.withLock { _confirmCounts[listingId] = count } }
    var deletedPhotos: [String] { lock.withLock { _deleted } }
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
    func publicListings(gymId: UUID) async throws -> PublicListings {
        try record("publicListings")
        let found = lock.withLock { () -> [RemoteListing] in
            _listingsAsked.append(gymId)
            return _byGym[gymId] ?? _listings
        }
        return PublicListings(listings: found, skipped: skipped, capped: capped)
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
        if lock.withLock({ _unshareable.contains(request.gymId) }) {
            lock.withLock { _requests.append(request) }
            throw GymCatalogError.gymNotShareable
        }
        let scripted: Result<ShareResult, GymCatalogError>? = lock.withLock {
            _requests.append(request)
            return _shareScript.isEmpty ? nil : _shareScript.removeFirst()
        }
        if let scripted { return try scripted.get() }
        let lost = lock.withLock { () -> Bool in
            if _serverShares[request.listingId] == nil {
                _serverShares[request.listingId] = request
                _shareOrder.append(request.listingId)
            }
            defer { _loseNextShareResponse = false }
            return _loseNextShareResponse
        }
        if lost { throw GymCatalogError.offline }
        return .created(request.listingId)
    }
    func confirm(listingId: UUID) async throws -> Int {
        try record("confirm")
        return lock.withLock {
            _confirmed.append(listingId)
            guard let count = _confirmCounts[listingId] else { return _confirmResult }
            guard _confirmers.insert(listingId).inserted else { return count }
            _confirmCounts[listingId] = count + 1
            return count + 1
        }
    }
    func uploadSharedPhoto(_ data: Data, name: String) async throws -> String {
        try record("uploadSharedPhoto")
        lock.withLock { _uploads.append(name) }
        return name
    }
    func deleteSharedPhoto(path: String) async throws {
        try record("deleteSharedPhoto")
        lock.withLock { _deleted.append(path) }
    }
    func deleteAllPhotos() async throws { try record("deleteAllPhotos") }
    func detachAllPhotos() async throws { try record("detachAllPhotos") }
    func report(targetType: GymTargetType, targetId: UUID, reason: ReportReason, note: String?) async throws {
        try record("report")
        if lock.withLock({ _stalledCalls.contains("report") }) { try await Task.sleep(for: .seconds(60)) }
        let scripted: GymCatalogError? = lock.withLock {
            _reports.append(ReportCall(type: targetType, id: targetId, reason: reason, note: note))
            _reportAnswers[targetId] = _ownTargets.contains(targetId) ? "own" : "reported"
            return _reportScript.isEmpty ? nil : _reportScript.removeFirst()
        }
        if let scripted { throw scripted }
    }
    func blockAuthor(targetType: GymTargetType, targetId: UUID) async throws {
        try record("blockAuthor")
        lock.withLock { _blocks.append(BlockCall(type: targetType, id: targetId)) }
    }
    func unblockAll() async throws -> Int {
        try record("unblockAll")
        return lock.withLock {
            _unblocks += 1
            return _unblockResult
        }
    }
    func isAdmin() async throws -> Bool { try record("isAdmin"); return true }
    func moderationQueue() async throws -> [ModerationEntry] { try record("moderationQueue"); return [] }
    func moderate(targetType: GymTargetType, targetId: UUID, action: ModerationAction) async throws -> String? {
        try record("moderate")
        return nil
    }
    func moderationPhotoDeleted(path: String) async throws { try record("moderationPhotoDeleted") }
    func publicPhotoURL(path: String) -> URL? { URL(string: "https://example.test/gym-photos/\(path)") }
}
