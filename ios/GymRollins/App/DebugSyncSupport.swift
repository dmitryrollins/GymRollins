#if DEBUG
import Foundation
import GymCore
import GymData
import GymSync

/// DEBUG-only: wraps a transport and fails every call as offline (`GYM_SIMULATE_OFFLINE=1`), for UI tests of
/// offline logging. Auth calls are not affected, so a stored session still restores.
struct OfflineTransport: SyncTransport {
    private func offline() -> URLError { URLError(.notConnectedToInternet) }

    func push(profile: ProfileDTO) async throws -> RowAck? { throw offline() }
    func push(customExercises: [CustomExerciseDTO]) async throws -> [RowAck] { throw offline() }
    func push(exercisePrefs: [ExercisePrefDTO]) async throws -> [RowAck] { throw offline() }
    func push(routines: [RoutineDTO]) async throws -> [RowAck] { throw offline() }
    func push(weekdays: [WeekdayDTO]) async throws -> [RowAck] { throw offline() }
    func push(bodyweight: [BodyweightDTO]) async throws -> [RowAck] { throw offline() }
    func push(workout: WorkoutDTO) async throws -> WorkoutPushResult { throw offline() }
    func pullProfile(since: Date?) async throws -> [ProfileDTO] { throw offline() }
    func pullCustomExercises(since: Date?) async throws -> [CustomExerciseDTO] { throw offline() }
    func pullExercisePrefs(since: Date?) async throws -> [ExercisePrefDTO] { throw offline() }
    func pullRoutines(since: Date?) async throws -> [RoutineDTO] { throw offline() }
    func pullWeekdays(since: Date?) async throws -> [WeekdayDTO] { throw offline() }
    func pullBodyweight(since: Date?) async throws -> [BodyweightDTO] { throw offline() }
    func pullWorkouts(since: Date?) async throws -> [WorkoutDTO] { throw offline() }
    func fetchWorkout(id: UUID) async throws -> WorkoutDTO? { throw offline() }
    func pendingProposals() async throws -> [PulledProposal] { throw offline() }
    func resolveProposal(id: UUID, status: String, appliedChangeIds: [String], at: Date) async throws { throw offline() }
}

/// DEBUG-only fake server for `-seedConflict`: accepts every push, except that the first workout it sees is
/// answered `stale` as if another device had edited it (one set fewer, one rep less per set). "Keep this
/// iPhone's" re-pushes with a newer edit time and is accepted; "Keep other" fetches the other version.
actor SeededConflictTransport: SyncTransport {
    private var remote: [UUID: WorkoutDTO] = [:]

    private func ack(_ id: String) -> RowAck { RowAck(id: id, updatedAt: Date()) }

    func push(profile: ProfileDTO) async throws -> RowAck? { ack(SyncStore.profileSyncID) }
    func push(customExercises: [CustomExerciseDTO]) async throws -> [RowAck] { customExercises.map { ack($0.id) } }
    func push(exercisePrefs: [ExercisePrefDTO]) async throws -> [RowAck] { exercisePrefs.map { ack($0.exerciseId) } }
    func push(routines: [RoutineDTO]) async throws -> [RowAck] { routines.map { ack($0.id.uuidString.lowercased()) } }
    func push(weekdays: [WeekdayDTO]) async throws -> [RowAck] { weekdays.map { ack(String($0.weekday)) } }
    func push(bodyweight: [BodyweightDTO]) async throws -> [RowAck] {
        bodyweight.map { ack($0.id.uuidString.lowercased()) }
    }

    func push(workout: WorkoutDTO) async throws -> WorkoutPushResult {
        if remote.isEmpty { remote[workout.id] = Self.otherDeviceEdit(of: workout) }
        if let theirs = remote[workout.id], !workout.force, workout.clientUpdatedAt <= theirs.clientUpdatedAt {
            return .stale(updatedAt: Date())
        }
        remote[workout.id] = workout
        return .ok(updatedAt: Date())
    }

    func pullProfile(since: Date?) async throws -> [ProfileDTO] { [] }
    func pullCustomExercises(since: Date?) async throws -> [CustomExerciseDTO] { [] }
    func pullExercisePrefs(since: Date?) async throws -> [ExercisePrefDTO] { [] }
    func pullRoutines(since: Date?) async throws -> [RoutineDTO] { [] }
    func pullWeekdays(since: Date?) async throws -> [WeekdayDTO] { [] }
    func pullBodyweight(since: Date?) async throws -> [BodyweightDTO] { [] }
    func pullWorkouts(since: Date?) async throws -> [WorkoutDTO] { [] }
    func fetchWorkout(id: UUID) async throws -> WorkoutDTO? { remote[id] }
    func pendingProposals() async throws -> [PulledProposal] { [] }
    func resolveProposal(id: UUID, status: String, appliedChangeIds: [String], at: Date) async throws {}

    private static func otherDeviceEdit(of dto: WorkoutDTO) -> WorkoutDTO {
        let row = dto.toDomain()
        let mine = row.value.workout
        let theirs = mine.with(entries: mine.entries.map { entry in
            entry.with(sets: entry.sets.dropLast().map { $0.with(weightKg: $0.weightKg, reps: max(1, $0.reps - 1)) })
        })
        let snapshot = WorkoutSnapshot(workout: theirs, records: [], volumeKg: WorkoutMetrics.volumeKg(theirs))
        return WorkoutDTO(SyncRow(value: snapshot, clientUpdatedAt: row.clientUpdatedAt.addingTimeInterval(0.001),
                                  serverUpdatedAt: Date()))
    }
}

/// DEBUG-only session store for UI tests against the local Worker: it survives relaunches like the Keychain, but
/// `-resetStore` and `-forgetSession` wipe it, so a relaunch can act as a fresh install or a revoked session.
final class UITestSessionStore: SessionStore, @unchecked Sendable {
    static let suiteName = "com.rollins.gymrollins.uitest-auth"
    private static let key = "session"
    private let defaults = UserDefaults(suiteName: UITestSessionStore.suiteName) ?? .standard
    private let lock = NSLock()

    static func wipe() { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

    func load() -> StoredSession? { lock.withLock { read() } }

    func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        lock.withLock { defaults.set(data, forKey: Self.key) }
    }

    @discardableResult func clear(ifToken token: String?) -> Bool {
        lock.withLock {
            if let token, read()?.token != token { return false }
            let held = defaults.data(forKey: Self.key) != nil
            defaults.removeObject(forKey: Self.key)
            return held
        }
    }

    private func read() -> StoredSession? {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(StoredSession.self, from: $0) }
    }
}
#endif
