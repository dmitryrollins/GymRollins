import Foundation
import SwiftData

/// Sync bookkeeping shared by every aggregate-root record.
protocol SyncTracked: AnyObject {
    var updatedAt: Date { get set }
    var serverUpdatedAt: Date? { get set }
    var dirty: Bool { get set }
}

extension ProfileRecord: SyncTracked {}
extension CustomExerciseRecord: SyncTracked {}
extension RoutineRecord: SyncTracked {}
extension WeekdayRecord: SyncTracked {}
extension MuscleTargetRecord: SyncTracked {}
extension BodyweightRecord: SyncTracked {}
extension WorkoutRecord: SyncTracked {}

/// The only sync-facing API over SwiftData: dirty rows out, remote rows in, and pull cursors.
///
/// Rules: dirty rows include tombstones; `markSynced` clears `dirty` only when the record was not edited after the
/// pushed edit time; remote rows never become dirty; dirty local rows are not overwritten by remote rows unless the
/// remote edit is newer (last write wins — the push would lose anyway). Workouts are the exception: a dirty workout
/// that changed remotely is reported as a conflict for the owner to resolve. The active workout never syncs.
@MainActor
public final class SyncStore {
    /// `markSynced` id for the singleton profile.
    public nonisolated static let profileSyncID = "profile"

    let context: ModelContext
    let now: () -> Date
    let defaults: UserDefaults

    public init(context: ModelContext, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.defaults = defaults
        self.now = now
    }

    // MARK: - Push acknowledgement

    /// Records that the server stored the row pushed with `clientUpdatedAt`. `serverUpdatedAt` is always stored
    /// (it is the server's current version, so its echo on the next pull is not mistaken for a remote change);
    /// `dirty` is cleared only if the record was not edited again while the push was in flight.
    public func markSynced(_ entity: SyncEntity, id: String, clientUpdatedAt: Date, serverUpdatedAt: Date) throws {
        guard let record = try trackedRecord(entity, id: id) else { return }
        record.serverUpdatedAt = serverUpdatedAt
        if record.updatedAt == clientUpdatedAt { record.dirty = false }
        try context.save()
        clearSyncFailure(entity, id: id)
    }

    private func trackedRecord(_ entity: SyncEntity, id: String) throws -> (any SyncTracked)? {
        switch entity {
        case .profile: return try profileRecord()
        case .customExercises: return try customExerciseRecord(id)
        case .exercisePreferences: return try exercisePreferenceRecord(id)
        case .weekSchedule: return try Int(id).flatMap { try weekdayRecord($0) }
        case .muscleTargets: return try muscleTargetRecord(id)
        case .routines: return try UUID(uuidString: id).flatMap { try routineRecord($0) }
        case .bodyweight: return try UUID(uuidString: id).flatMap { try bodyweightRecord($0) }
        case .workouts: return try UUID(uuidString: id).flatMap { try workoutRecord($0) }
        case .proposals: return nil // resolutions are marked synced by markProposalSynced
        }
    }

    // MARK: - Cursors

    public func cursor(for entity: SyncEntity) -> Date? {
        defaults.object(forKey: Self.cursorKey(entity)) as? Date
    }

    public func setCursor(_ date: Date, for entity: SyncEntity) {
        defaults.set(date, forKey: Self.cursorKey(entity))
    }

    private static func cursorKey(_ entity: SyncEntity) -> String { "gymrollins.sync.cursor.\(entity.rawValue)" }

    // MARK: - Reset

    /// Sign-out / account deletion / account switch: deletes every local record and forgets the cursors, the
    /// owning account and any recorded sync failures.
    public func resetAll() throws {
        // Roots first (their relationships cascade), then any orphaned children. Batch deletes are avoided:
        // they fail on the non-optional inverse relationships.
        try deleteAll(WorkoutRecord.self)
        try deleteAll(WorkoutEntryRecord.self)
        try deleteAll(SetRecord.self)
        try deleteAll(RoutineRecord.self)
        try deleteAll(RoutineExerciseRecord.self)
        try deleteAll(WeekdayRecord.self)
        try deleteAll(MuscleTargetRecord.self)
        try deleteAll(BodyweightRecord.self)
        try deleteAll(CustomExerciseRecord.self)
        try deleteAll(ExercisePreferenceRecord.self)
        try deleteAll(ProfileRecord.self)
        try deleteAll(ProposalRecord.self)
        try context.save()
        SyncEntity.allCases.forEach { defaults.removeObject(forKey: Self.cursorKey($0)) }
        forgetOwnershipAndFailures()
    }

    private func deleteAll<T: PersistentModel>(_ type: T.Type) throws {
        try context.fetch(FetchDescriptor<T>()).forEach(context.delete)
    }

    // MARK: - Shared helpers

    /// Whether a remote row may replace this local record: clean rows always, dirty rows only when the remote
    /// edit is newer (the local push would be rejected by the server's last-write-wins guard).
    func remoteWins(over record: any SyncTracked, remoteEdit: Date) -> Bool {
        !record.dirty || remoteEdit > record.updatedAt
    }

    /// Stamps a record as holding exactly the server's version.
    func markClean(_ record: any SyncTracked, clientUpdatedAt: Date, serverUpdatedAt: Date?) {
        record.updatedAt = clientUpdatedAt
        record.serverUpdatedAt = serverUpdatedAt
        record.dirty = false
    }

    func profileRecord() throws -> ProfileRecord? {
        let id = ProfileRecord.singletonID
        return try context.fetch(FetchDescriptor<ProfileRecord>(predicate: #Predicate { $0.id == id })).first
    }

    func customExerciseRecord(_ id: String) throws -> CustomExerciseRecord? {
        try context.fetch(FetchDescriptor<CustomExerciseRecord>(predicate: #Predicate { $0.id == id })).first
    }

    func weekdayRecord(_ weekday: Int) throws -> WeekdayRecord? {
        try context.fetch(FetchDescriptor<WeekdayRecord>(predicate: #Predicate { $0.weekday == weekday })).first
    }

    func routineRecord(_ id: UUID) throws -> RoutineRecord? {
        try context.fetch(FetchDescriptor<RoutineRecord>(predicate: #Predicate { $0.id == id })).first
    }

    func bodyweightRecord(_ id: UUID) throws -> BodyweightRecord? {
        try context.fetch(FetchDescriptor<BodyweightRecord>(predicate: #Predicate { $0.id == id })).first
    }

    func workoutRecord(_ id: UUID) throws -> WorkoutRecord? {
        try context.fetch(FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })).first
    }
}
