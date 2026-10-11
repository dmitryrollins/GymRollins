import Foundation
import GymCore
import GymData
import GymSync
import SwiftData
import Testing
@testable import GymRollins

/// A server whose profile pull can be held open (to overlap a round with sign-out) and that always has one
/// routine "from another device" to pull. Every push is acknowledged.
private actor ScriptedTransport: SyncTransport {
    private var holdProfilePull = false
    private var held: CheckedContinuation<Void, Never>?
    private(set) var pushes = 0
    private let remoteRoutine: RoutineDTO

    init(now: Date) {
        let routine = Routine(name: "Remote", exercises: [])
        remoteRoutine = RoutineDTO(SyncRow(value: RoutineSnapshot(routine: routine, position: 0), clientUpdatedAt: now,
                                           serverUpdatedAt: now))
    }

    func holdNextProfilePull() { holdProfilePull = true }
    var isHolding: Bool { held != nil }
    func release() { held?.resume(); held = nil }

    private func ack(_ id: String) -> RowAck { RowAck(id: id, updatedAt: Date()) }
    func push(profile: ProfileDTO) async throws -> RowAck? { pushes += 1; return ack(SyncStore.profileSyncID) }
    func push(customExercises: [CustomExerciseDTO]) async throws -> [RowAck] {
        pushes += 1; return customExercises.map { ack($0.id) }
    }
    func push(exercisePrefs: [ExercisePrefDTO]) async throws -> [RowAck] {
        pushes += 1; return exercisePrefs.map { ack($0.exerciseId) }
    }
    func push(routines: [RoutineDTO]) async throws -> [RowAck] {
        pushes += 1; return routines.map { ack($0.id.uuidString.lowercased()) }
    }
    func push(weekdays: [WeekdayDTO]) async throws -> [RowAck] { pushes += 1; return weekdays.map { ack(String($0.weekday)) } }
    func push(bodyweight: [BodyweightDTO]) async throws -> [RowAck] {
        pushes += 1; return bodyweight.map { ack($0.id.uuidString.lowercased()) }
    }
    func push(workout: WorkoutDTO) async throws -> WorkoutPushResult { pushes += 1; return .ok(updatedAt: Date()) }

    func pullProfile(since: Date?) async throws -> [ProfileDTO] {
        if holdProfilePull {
            holdProfilePull = false
            await withCheckedContinuation { held = $0 }
        }
        return []
    }
    func pullCustomExercises(since: Date?) async throws -> [CustomExerciseDTO] { [] }
    func pullExercisePrefs(since: Date?) async throws -> [ExercisePrefDTO] { [] }
    func pullRoutines(since: Date?) async throws -> [RoutineDTO] { since == nil ? [remoteRoutine] : [] }
    func pullWeekdays(since: Date?) async throws -> [WeekdayDTO] { [] }
    func pullBodyweight(since: Date?) async throws -> [BodyweightDTO] { [] }
    func pullWorkouts(since: Date?) async throws -> [WorkoutDTO] { [] }
    func fetchWorkout(id: UUID) async throws -> WorkoutDTO? { nil }
    func pendingProposals() async throws -> [PulledProposal] { [] }
    func resolveProposal(id: UUID, status: String, appliedChangeIds: [String], at: Date) async throws {}
}

@MainActor
@Suite struct SyncAccountSafetyTests {
    let container: ModelContainer
    let defaults: UserDefaults
    let suite = "account-safety-\(UUID())"
    let now = ISO8601DateFormatter().date(from: "2026-09-26T09:00:00Z")!
    let userA = UUID()
    let userB = UUID()

    init() throws {
        container = try GymStore.container(inMemory: true)
        defaults = UserDefaults(suiteName: suite)!
    }

    private var store: SyncStore { SyncStore(context: container.mainContext, defaults: defaults, now: Date.init) }
    private var routines: RoutineRepository { RoutineRepository(context: container.mainContext, now: Date.init) }

    /// A coordinator with a real AuthService whose auth events the test drives.
    private func signedInCoordinator(_ transport: ScriptedTransport)
        -> (SyncCoordinator, AsyncStream<AuthEvent>.Continuation) {
        let (events, continuation) = AsyncStream<AuthEvent>.makeStream()
        let client = SupabaseConfig(url: URL(string: "http://127.0.0.1:9")!, anonKey: "anon")
            .makeClient(storage: InMemoryAuthStorage())
        let auth = AuthService(client: client, events: events)
        let sync = SyncCoordinator(auth: auth, store: store, now: Date.init, makeTransport: { _ in transport })
        return (sync, continuation)
    }

    private func saveLocalRoutine() throws -> Routine {
        let routine = Routine(name: "Local", exercises: [])
        try routines.upsert(routine)
        return routine
    }

    // MARK: Codex P1 #2 — sign-out overlapping a round

    @Test func signOutDuringAPullLeavesTheStoreEmpty() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = ScriptedTransport(now: now)
        let sync = SyncCoordinator(auth: nil, store: store, now: Date.init, makeTransport: { _ in transport })
        _ = try saveLocalRoutine()
        await sync.start()          // first round (no hold) creates the engine
        sync.setActive(false)
        try store.resetAll()
        await transport.holdNextProfilePull()

        let round = Task { await sync.syncNow() }
        try await waitUntil { await transport.isHolding }
        let signOut = Task { try await sync.signOutAndRemoveLocalData() }
        try await waitUntil { sync.engine == nil } // sign-out dropped the engine and waits for the round
        await transport.release()   // the pull answers only after sign-out began
        try await signOut.value
        await round.value

        #expect(try routines.all().isEmpty)
        #expect(SyncEntity.allCases.allSatisfy { store.cursor(for: $0) == nil })
        #expect(sync.engine == nil)
    }

    // MARK: Codex P1 #3 — local data ownership

    @Test func anonymousLocalDataIsAdoptedAndUploaded() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = ScriptedTransport(now: now)
        let (sync, events) = signedInCoordinator(transport)
        let local = try saveLocalRoutine()
        #expect(store.ownerUserId == nil)

        events.yield(.signedIn(userId: userA, email: "a@test.local"))
        try await waitUntil { sync.lastSyncedAt != nil }

        #expect(store.ownerUserId == userA)
        #expect(!sync.accountSwitchPending)
        #expect(try routines.routine(local.id) != nil)
        #expect(await transport.pushes > 0)
        #expect(sync.pendingChanges == 0)
    }

    @Test func anotherAccountsDataRequiresConfirmationThenIsRemoved() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = ScriptedTransport(now: now)
        let (sync, events) = signedInCoordinator(transport)
        let local = try saveLocalRoutine()
        store.ownerUserId = userB

        events.yield(.signedIn(userId: userA, email: "a@test.local"))
        try await waitUntil { sync.accountSwitchPending }
        #expect(sync.engine == nil)
        #expect(await transport.pushes == 0)          // B's rows never went up under A
        #expect(try routines.routine(local.id) != nil)

        var resets = 0
        sync.onLocalDataReset = { resets += 1 }
        try await sync.confirmAccountSwitch()
        #expect(resets == 1)
        #expect(!sync.accountSwitchPending)
        #expect(store.ownerUserId == userA)
        #expect(try routines.routine(local.id) == nil)
        #expect(try routines.all().map(\.name) == ["Remote"])  // A's own data pulled from scratch
    }

    @Test func cancellingTheSwitchSignsOutAndKeepsTheData() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = ScriptedTransport(now: now)
        let (sync, events) = signedInCoordinator(transport)
        let local = try saveLocalRoutine()
        store.ownerUserId = userB

        events.yield(.signedIn(userId: userA, email: nil))
        try await waitUntil { sync.accountSwitchPending }
        try await sync.cancelAccountSwitch()

        #expect(sync.authState == .signedOut)
        #expect(!sync.accountSwitchPending)
        #expect(store.ownerUserId == userB)
        #expect(try routines.routine(local.id) != nil)
    }

    @Test func switchingToAnAccountWithEmptyLocalStoreNeedsNoConfirmation() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = ScriptedTransport(now: now)
        let (sync, events) = signedInCoordinator(transport)
        store.ownerUserId = userB  // e.g. everything was deleted locally

        events.yield(.signedIn(userId: userA, email: nil))
        try await waitUntil { sync.lastSyncedAt != nil }
        #expect(!sync.accountSwitchPending)
        #expect(store.ownerUserId == userA)
    }

    // MARK: Codex P2 #7 — session invalidated elsewhere

    @Test func revokedSessionDropsTheEngineButKeepsDataAndOwner() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = ScriptedTransport(now: now)
        let (sync, events) = signedInCoordinator(transport)
        let local = try saveLocalRoutine()
        events.yield(.signedIn(userId: userA, email: nil))
        try await waitUntil { sync.engine != nil && sync.lastSyncedAt != nil }

        events.yield(.signedOut)  // the SDK's refresh found the session revoked
        try await waitUntil { sync.engine == nil }

        #expect(sync.authState == .signedOut)
        #expect(store.ownerUserId == userA)
        #expect(try routines.routine(local.id) != nil)

        // Signing back in as the same account resumes syncing without any prompt.
        events.yield(.signedIn(userId: userA, email: nil))
        try await waitUntil { sync.engine != nil }
        #expect(!sync.accountSwitchPending)
    }
}

/// Codex P1 #4: wiping local data ends the in-progress workout.
@MainActor
@Suite struct LocalResetSessionTests {
    @Test func signOutEndsTheActiveWorkoutAndItNeverComesBack() async throws {
        let suite = "reset-session-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]), defaults: defaults)
        env.startSession(routine: try env.routines.all().first)
        let old = try #require(env.session)
        #expect(try env.workouts.active() != nil)

        try await env.sync.signOutAndRemoveLocalData()

        #expect(env.session == nil)
        #expect(old.isAbandoned)
        #expect(try env.workouts.active() == nil)
        // A screen still holding the old session edits it: nothing is written back.
        if let entry = old.workout.entries.first {
            old.addSet(entryId: entry.id)
            old.logNextSet(entryId: entry.id, weightKg: 60, reps: 8)
        }
        #expect(throws: (any Error).self) { try old.finish(discardingUndone: true) }
        #expect(try env.workouts.active() == nil)
        #expect(try env.workouts.recent(limit: 5).isEmpty)
        #expect(old.activeRest(at: Date()) == nil)
    }
}
