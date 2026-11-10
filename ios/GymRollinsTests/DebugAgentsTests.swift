import Foundation
import GymCore
import GymData
import GymSync
import Testing
@testable import GymRollins

/// The DEBUG seeds the hermetic UI tests use for plan 32.
@MainActor
@Suite struct DebugAgentsTests {
    private func makeEnv(_ arguments: [String]) throws -> AppEnvironment {
        let defaults = try #require(UserDefaults(suiteName: "DebugAgentsTests.\(UUID())"))
        return try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"] + arguments), defaults: defaults)
    }

    @Test func theLaunchFlagsAreRead() {
        let options = LaunchOptions(arguments: ["-uiTesting", "-fakeAgents", "-seedAgentWorkout"])
        #expect(options.fakeAgents && options.seedAgentWorkout)
        let plain = LaunchOptions(arguments: ["-uiTesting"])
        #expect(!plain.fakeAgents && !plain.seedAgentWorkout)
    }

    @Test func fakeAgentsAreMuseThenClaudeAndDisconnectRemovesOneForTheLaunch() async throws {
        let env = try makeEnv(["-fakeAgents"])
        let listed = try await env.agentCalls.list()
        #expect(listed.map(\.name) == ["Muse", "Claude"])
        #expect(listed.map(\.clientId) == [DebugAgents.museId, DebugAgents.claudeId])
        #expect(listed.map(\.host) == ["agent.meta.ai", "claude.ai"])
        #expect(AgentText.lastUsed(listed[0].lastUsedAt, now: env.now()) == "Last used 2 h ago")
        #expect(listed[1].lastUsedAt == nil)

        try await env.agentCalls.disconnect(DebugAgents.museId)
        #expect(try await env.agentCalls.list().map(\.name) == ["Claude"]) // the same list, asked again
        await #expect(throws: AgentError.unknownAgent) { try await env.agentCalls.disconnect(DebugAgents.museId) }
    }

    @Test func withoutTheFlagTheAccountIsAsked() async throws {
        let env = try makeEnv([])
        // Hermetic: no session, so the account can't be asked.
        await #expect(throws: SyncUnavailableError.self) { try await env.agentCalls.list() }
    }

    @Test func theSeededWorkoutWasAddedByMuseAndStoredAsAPull() throws {
        let env = try makeEnv(["-seedAgentWorkout"])
        let workout = try #require(try env.workouts.workout(DebugAgents.workoutId))
        #expect(workout.name == "Upper" && workout.source == .import)
        #expect(workout.entries.first?.sets.map(\.reps) == [8, 8, 7])
        #expect(try env.workouts.addedBy(DebugAgents.workoutId) == "Muse")
        #expect(try env.syncStore.dirtyWorkouts().isEmpty)
    }

    @Test func theSeededProposalIsFromClaude() throws {
        let env = try makeEnv(["-seedProposal"])
        #expect(try env.proposals.proposal(DebugProposalSeed.id)?.fromAgent == "Claude")
    }
}
