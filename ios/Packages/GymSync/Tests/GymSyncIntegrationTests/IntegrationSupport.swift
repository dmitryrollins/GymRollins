import Foundation
import GymCore
import GymData
import Supabase
import SwiftData
import Testing
@testable import GymSync

/// Integration suites run only against the local stack (`scripts/test-sync-integration.sh` sets these).
let supabaseConfigured = ProcessInfo.processInfo.environment["SUPABASE_URL"] != nil
    && ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"] != nil

enum IntegrationEnv {
    static let password = "sync-test-password-1"

    static func config() throws -> SupabaseConfig { try SupabaseConfig(environment: ProcessInfo.processInfo.environment) }

    static func uniqueEmail() -> String { "sync-\(UUID().uuidString.lowercased())@test.local" }

    /// Hands deleted user ids to the shell script, which checks with admin SQL that no rows survived.
    static func recordDeletedUser(_ id: UUID) {
        guard let path = ProcessInfo.processInfo.environment["SYNC_DELETED_USERS_FILE"],
              let line = (id.uuidString.lowercased() + "\n").data(using: .utf8),
              let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}

/// A signed-in user on one simulated device (its own client and session storage).
@MainActor
struct Account {
    let email: String
    let auth: AuthService
    var transport: SupabaseTransport { SupabaseTransport(client: auth.client) }
    var userId: UUID { auth.state.userId! }

    static func signUp() async throws -> Account {
        let account = try fresh(email: IntegrationEnv.uniqueEmail())
        try await account.auth.signUp(email: account.email, password: IntegrationEnv.password)
        return account
    }

    /// The same user signing in on another device.
    func onAnotherDevice() async throws -> Account {
        let other = try Account.fresh(email: email)
        try await other.auth.signIn(email: email, password: IntegrationEnv.password)
        return other
    }

    func deleteAccount() async throws {
        let id = userId
        try await auth.deleteAccount()
        IntegrationEnv.recordDeletedUser(id)
    }

    static func fresh(email: String) throws -> Account {
        Account(email: email, auth: AuthService(client: try IntegrationEnv.config().makeClient(storage: InMemoryAuthStorage())))
    }
}

@MainActor
final class DeviceClock {
    var now: Date
    init(_ iso: String) { now = SyncDate.parse(iso)! }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// A fresh in-memory SwiftData store + SyncEngine talking to the real local Supabase as `account`.
@MainActor
struct Device {
    let container: ModelContainer
    let clock: DeviceClock
    let suiteName = "sync-it-\(UUID())"
    let store: SyncStore
    let engine: SyncEngine

    init(_ account: Account, clock: DeviceClock) throws {
        container = try GymStore.container(inMemory: true)
        self.clock = clock
        let defaults = UserDefaults(suiteName: suiteName)!
        store = SyncStore(context: container.mainContext, defaults: defaults, now: { clock.now })
        engine = SyncEngine(store: store, transport: account.transport, now: { clock.now })
    }

    var routines: RoutineRepository { RoutineRepository(context: container.mainContext, now: { [clock] in clock.now }) }
    var workouts: WorkoutRepository { WorkoutRepository(context: container.mainContext, now: { [clock] in clock.now }) }
    var prefs: ExercisePreferenceRepository {
        ExercisePreferenceRepository(context: container.mainContext, now: { [clock] in clock.now })
    }
    var body: BodyRepository { BodyRepository(context: container.mainContext, now: { [clock] in clock.now }) }
    var profiles: ProfileRepository { ProfileRepository(context: container.mainContext, now: { [clock] in clock.now }) }

    func tearDown() { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
}

/// A finished three-set bench session; `startedAt` is on the microsecond grid so it round-trips exactly.
func finishedWorkout(id: UUID = UUID(), name: String, at start: Date) -> Workout {
    let done = start.addingTimeInterval(600.25)
    return Workout(id: id, startedAt: start, endedAt: start.addingTimeInterval(3_000.5), pausedSeconds: 42.5,
                   name: name, entries: [
                       WorkoutEntry(exerciseId: "bench", sets: [
                           WorkoutSet(weightKg: 60, reps: 8, done: true, rir: 2, completedAt: done),
                           WorkoutSet(weightKg: 61.234567, reps: 8, done: true, rpe: 8.5, completedAt: done),
                           WorkoutSet(weightKg: 62.5, reps: 7, done: true, completedAt: done),
                       ], note: "felt strong"),
                   ], note: "push day")
}

let benchRecords = [
    PersonalRecord(exerciseId: "bench", kind: .e1RM, valueKg: 76.47, reps: nil, weightKg: nil, previousKg: 74.1),
    PersonalRecord(exerciseId: "bench", kind: .repsAtWeight, valueKg: nil, reps: 8, weightKg: 61.234567,
                   previousKg: nil),
]
