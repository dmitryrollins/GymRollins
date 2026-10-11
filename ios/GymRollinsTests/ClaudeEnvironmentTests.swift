import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@MainActor
@Suite struct ClaudeEnvironmentTests {
    private func makeEnv() throws -> AppEnvironment {
        let defaults = try #require(UserDefaults(suiteName: "ClaudeEnvironmentTests.\(UUID())"))
        return try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]), defaults: defaults)
    }

    /// Codex P2 #4: a sync round pulls a custom exercise and a proposal that adds it; the auto-apply hook runs
    /// before `onRemoteChanges` reloads the library, so it must reload it itself.
    @Test func autoApplyAfterPullSeesCustomExercisesPulledInTheSameRound() throws {
        let env = try makeEnv()
        try env.profiles.setMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, propose: true,
                                           autoApply: true)
        let routine = try #require(try env.routines.all().first)
        // Written straight to the store, as a pull does: the cached library doesn't know it yet.
        let sled = try env.customExercises.create(name: "Sled push", bodyPart: "upper legs", equipment: "sled",
                                                  target: "quads", mode: .reps, bilateral: true)
        #expect(env.library.exercise(sled.id) == nil)
        try env.proposals.upsertRemote([Proposal(id: UUID(), createdAt: env.now(), summary: "Add sled", changes: [
            PlanChange(id: "c1", type: .addExercise, routineId: routine.id.uuidString.lowercased(),
                       exerciseId: sled.id, sets: 3, reps: 10),
        ])])

        #expect(try env.sync.autoApply() == 1)
        #expect(try env.routines.routine(routine.id)?.exercises.contains { $0.exerciseId == sled.id } == true)
        #expect(env.pendingProposals().isEmpty)
    }

    @Test func disconnectTurnsEveryPermissionOffEvenWithoutASession() async throws {
        let env = try makeEnv()
        try env.saveMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, propose: true, autoApply: true)
        #expect(try await env.disconnectClaude() == 0) // hermetic build: no session, nothing to revoke
        let p = env.profile
        #expect(!p.mcpReadWorkouts && !p.mcpReadBody && !p.mcpReadPlan && !p.mcpPropose && !p.mcpAutoApply)
    }

    @Test func readPlanPermissionIsSavedAndReloaded() throws {
        let env = try makeEnv()
        #expect(env.profile.mcpReadPlan)
        try env.saveMcpPermissions(readWorkouts: true, readBody: true, readPlan: false, propose: true, autoApply: false)
        #expect(!env.profile.mcpReadPlan && env.profile.mcpReadWorkouts)
    }
}
