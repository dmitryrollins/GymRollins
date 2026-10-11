#if DEBUG
import Foundation
import GymCore
import GymData
import GymSync
import Supabase

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

/// DEBUG-only auth session store for UI tests against the local stack: survives relaunches like the Keychain,
/// but `-resetStore` wipes it so a relaunch behaves like a fresh install.
final class UITestAuthStorage: AuthLocalStorage, @unchecked Sendable {
    static let suiteName = "com.rollins.gymrollins.uitest-auth"
    private let defaults = UserDefaults(suiteName: UITestAuthStorage.suiteName) ?? .standard

    static func wipe() { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

    func store(key: String, value: Data) throws { defaults.set(value, forKey: key) }
    func retrieve(key: String) throws -> Data? { defaults.data(forKey: key) }
    func remove(key: String) throws { defaults.removeObject(forKey: key) }
}
#endif
