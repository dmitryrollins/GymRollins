import Foundation
import GymCore
import GymData
import GymSync
import Testing
@testable import GymRollins

/// A server whose pushes can fail (offline), whose profile push can fail or be refused as "newer edit kept", and
/// whose OAuth revoke can fail on its own. Counts profile pushes and revokes.
private actor SwitchableTransport: SyncTransport {
    enum ProfileMode { case store, offline, keepNewer }
    private(set) var profileMode = ProfileMode.store
    private(set) var offline = false
    private(set) var revokeFails = false
    private(set) var profilePushes = 0
    private(set) var revokes = 0
    private(set) var storedProfile: ProfileDTO?

    func set(profile mode: ProfileMode) { profileMode = mode }
    func set(offline value: Bool) { offline = value }
    func set(revokeFails value: Bool) { revokeFails = value }

    private func gate() throws { if offline { throw URLError(.notConnectedToInternet) } }
    private func ack(_ id: String) -> RowAck { RowAck(id: id, updatedAt: Date()) }

    func push(profile: ProfileDTO) async throws -> RowAck? {
        profilePushes += 1
        try gate()
        switch profileMode {
        case .offline: throw URLError(.notConnectedToInternet)
        case .keepNewer: return nil
        case .store:
            storedProfile = profile
            return ack(SyncStore.profileSyncID)
        }
    }
    func push(customExercises: [CustomExerciseDTO]) async throws -> [RowAck] {
        try gate()
        return customExercises.map { ack($0.id) }
    }
    func push(exercisePrefs: [ExercisePrefDTO]) async throws -> [RowAck] {
        try gate()
        return exercisePrefs.map { ack($0.exerciseId) }
    }
    func push(routines: [RoutineDTO]) async throws -> [RowAck] {
        try gate()
        return routines.map { ack($0.id.uuidString.lowercased()) }
    }
    func push(weekdays: [WeekdayDTO]) async throws -> [RowAck] {
        try gate()
        return weekdays.map { ack(String($0.weekday)) }
    }
    func push(bodyweight: [BodyweightDTO]) async throws -> [RowAck] {
        try gate()
        return bodyweight.map { ack($0.id.uuidString.lowercased()) }
    }
    func push(workout: WorkoutDTO) async throws -> WorkoutPushResult {
        try gate()
        return .ok(updatedAt: Date())
    }
    func pullProfile(since: Date?) async throws -> [ProfileDTO] {
        try gate()
        return []
    }
    func pullCustomExercises(since: Date?) async throws -> [CustomExerciseDTO] { [] }
    func pullExercisePrefs(since: Date?) async throws -> [ExercisePrefDTO] { [] }
    func pullRoutines(since: Date?) async throws -> [RoutineDTO] { [] }
    func pullWeekdays(since: Date?) async throws -> [WeekdayDTO] { [] }
    func pullBodyweight(since: Date?) async throws -> [BodyweightDTO] { [] }
    func pullWorkouts(since: Date?) async throws -> [WorkoutDTO] { [] }
    func fetchWorkout(id: UUID) async throws -> WorkoutDTO? { nil }
    func pendingProposals() async throws -> [PulledProposal] { [] }
    func resolveProposal(id: UUID, status: String, appliedChangeIds: [String], at: Date) async throws {}
    func revokeOAuthGrants() async throws -> Int {
        try gate()
        if revokeFails { throw URLError(.timedOut) }
        revokes += 1
        return 1
    }
}

@MainActor
private func makeEnv(_ transport: SwitchableTransport) async throws -> AppEnvironment {
    let defaults = try #require(UserDefaults(suiteName: "SignOutAndDisconnectTests.\(UUID())"))
    let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]), defaults: defaults,
                                 makeSync: { store, now in
                                     SyncCoordinator(auth: nil, store: store, now: now,
                                                     makeTransport: { _ in transport })
                                 })
    await env.sync.start() // creates the engine and uploads the seeded data
    env.sync.setActive(false)
    return env
}

/// Codex P1: Disconnect Claude reports success only when the permissions-off profile is stored AND the grant is
/// revoked.
@MainActor
@Suite struct ClaudeDisconnectTests {
    @Test func successPushesTheFlagsBeforeRevoking() async throws {
        let transport = SwitchableTransport()
        let env = try await makeEnv(transport)
        try env.saveMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, propose: true, autoApply: true)
        let pushesBefore = await transport.profilePushes

        #expect(try await env.disconnectClaude() == 1)

        #expect(await transport.profilePushes > pushesBefore)
        #expect(await transport.storedProfile?.mcpReadWorkouts == false)
        #expect(await transport.storedProfile?.mcpPropose == false)
        #expect(await transport.revokes == 1)
        #expect(try env.syncStore.dirtyProfile() == nil)
    }

    @Test func profilePushFailureIsAnErrorAndSkipsTheRevoke() async throws {
        let transport = SwitchableTransport()
        let env = try await makeEnv(transport)
        await transport.set(profile: .offline)

        await #expect(throws: ClaudeDisconnectError.permissionsNotSaved) { try await env.disconnectClaude() }
        #expect(await transport.revokes == 0)
        #expect(!env.profile.mcpReadWorkouts) // off on this iPhone regardless

        await transport.set(profile: .keepNewer)
        await #expect(throws: ClaudeDisconnectError.permissionsNotSaved) { try await env.disconnectClaude() }
        #expect(await transport.revokes == 0)

        await transport.set(profile: .store) // retrying works
        #expect(try await env.disconnectClaude() == 1)
    }

    @Test func revokeFailureIsReportedAfterTheFlagsAreStored() async throws {
        let transport = SwitchableTransport()
        let env = try await makeEnv(transport)
        await transport.set(revokeFails: true)

        await #expect(throws: ClaudeDisconnectError.accessNotRevoked) { try await env.disconnectClaude() }
        #expect(await transport.storedProfile?.mcpReadBody == false)
        #expect(await transport.revokes == 0)
    }
}

/// Codex P1: signing out after a last sync warns about exactly what would be deleted.
@MainActor
@Suite struct SignOutSafetyTests {
    @Test func warningListsUnsyncedChangesAndTheWorkoutInProgress() {
        #expect(SignOutReport(unsynced: 2, failed: 0, workoutInProgress: true).warning
                == "2 changes not uploaded, 1 workout in progress will be deleted from this iPhone.")
        #expect(SignOutReport(unsynced: 1, failed: 1, workoutInProgress: false).warning
                == "1 change not uploaded, 1 change the server refused will be deleted from this iPhone.")
        #expect(SignOutReport(unsynced: 0, failed: 0, workoutInProgress: false).isSafe)
        #expect(!SignOutReport(unsynced: 0, failed: 0, workoutInProgress: true).isSafe)
    }

    @Test func everythingUploadedIsSafe() async throws {
        let env = try await makeEnv(SwitchableTransport())
        try env.body.add(BodyweightEntry(date: env.now(), weightKg: 80))
        let report = await env.prepareSignOut()
        #expect(report.isSafe)
    }

    @Test func offlineChangesAndAnActiveWorkoutAreReported() async throws {
        let transport = SwitchableTransport()
        let env = try await makeEnv(transport)
        await transport.set(offline: true)
        try env.body.add(BodyweightEntry(date: env.now(), weightKg: 80))
        try env.body.add(BodyweightEntry(date: env.now().addingTimeInterval(-86_400), weightKg: 80.5))
        env.startSession(routine: try env.routines.all().first)

        let report = await env.prepareSignOut() // the last sync attempt fails offline

        #expect(report == SignOutReport(unsynced: 2, failed: 0, workoutInProgress: true))
        #expect(report.warning == "2 changes not uploaded, 1 workout in progress will be deleted from this iPhone.")

        await transport.set(offline: false)
        let afterReconnect = await env.prepareSignOut()
        #expect(afterReconnect.unsynced == 0 && afterReconnect.workoutInProgress && !afterReconnect.isSafe)
    }
}
