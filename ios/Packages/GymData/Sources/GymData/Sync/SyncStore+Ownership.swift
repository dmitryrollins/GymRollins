import Foundation
import SwiftData

/// A local row the server refused (a CHECK/type violation, e.g. a value out of range). The edit with
/// `clientUpdatedAt` is not pushed again; a later edit of the same record retries, and a successful push clears it.
public struct SyncFailure: Codable, Sendable, Equatable {
    public let entity: SyncEntity
    public let id: String
    public let clientUpdatedAt: Date
    public let message: String

    public init(entity: SyncEntity, id: String, clientUpdatedAt: Date, message: String) {
        self.entity = entity
        self.id = id
        self.clientUpdatedAt = clientUpdatedAt
        self.message = message
    }

    var key: String { SyncFailure.key(entity, id) }
    static func key(_ entity: SyncEntity, _ id: String) -> String { "\(entity.rawValue)/\(id.lowercased())" }
}

extension SyncEntity: Codable {}

// Account ownership of the local copy, and per-record sync failures.
extension SyncStore {
    private static let ownerKey = "gymrollins.sync.owner"
    private static let failuresKey = "gymrollins.sync.failures"

    /// The account this iPhone's data belongs to; nil for data never synced by a signed-in user (e.g. created
    /// before signing in). Kept across a revoked session, so a different account can't silently take it over.
    public var ownerUserId: UUID? {
        get { defaults.string(forKey: Self.ownerKey).flatMap(UUID.init(uuidString:)) }
        set {
            if let newValue { defaults.set(newValue.uuidString, forKey: Self.ownerKey) }
            else { defaults.removeObject(forKey: Self.ownerKey) }
        }
    }

    /// Whether any user data is stored locally (tombstones included).
    public func hasLocalData() throws -> Bool {
        try context.fetchCount(FetchDescriptor<ProfileRecord>()) > 0
            || context.fetchCount(FetchDescriptor<CustomExerciseRecord>()) > 0
            || context.fetchCount(FetchDescriptor<ExercisePreferenceRecord>()) > 0
            || context.fetchCount(FetchDescriptor<RoutineRecord>()) > 0
            || context.fetchCount(FetchDescriptor<WeekdayRecord>()) > 0
            || context.fetchCount(FetchDescriptor<MuscleTargetRecord>()) > 0
            || context.fetchCount(FetchDescriptor<BodyweightRecord>()) > 0
            || context.fetchCount(FetchDescriptor<WorkoutRecord>()) > 0
    }

    // MARK: Sync failures

    public func syncFailures() -> [SyncFailure] {
        failureMap().values.sorted { ($0.entity.rawValue, $0.id) < ($1.entity.rawValue, $1.id) }
    }

    public func recordSyncFailure(_ failure: SyncFailure) {
        var map = failureMap()
        map[failure.key] = failure
        saveFailures(map)
    }

    /// True when exactly this edit (`clientUpdatedAt`) was already refused by the server.
    public func isSyncBlocked(_ entity: SyncEntity, id: String, clientUpdatedAt: Date) -> Bool {
        failureMap()[SyncFailure.key(entity, id)]?.clientUpdatedAt == clientUpdatedAt
    }

    func clearSyncFailure(_ entity: SyncEntity, id: String) {
        var map = failureMap()
        guard map.removeValue(forKey: SyncFailure.key(entity, id)) != nil else { return }
        saveFailures(map)
    }

    func forgetOwnershipAndFailures() {
        defaults.removeObject(forKey: Self.ownerKey)
        defaults.removeObject(forKey: Self.failuresKey)
    }

    private func failureMap() -> [String: SyncFailure] {
        guard let data = defaults.data(forKey: Self.failuresKey),
              let list = try? JSONDecoder().decode([SyncFailure].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
    }

    private func saveFailures(_ map: [String: SyncFailure]) {
        if map.isEmpty { defaults.removeObject(forKey: Self.failuresKey); return }
        guard let data = try? JSONEncoder().encode(Array(map.values)) else { return }
        defaults.set(data, forKey: Self.failuresKey)
    }
}
