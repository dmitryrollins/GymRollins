import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// Plan 32 against the local Worker: agents (real OAuth clients, `ClaudeTestClient`) connect to one account, and the
/// owner's transport lists them, disconnects one while the other keeps working, pulls a proposal with its sender's
/// label ("<name> (local)" for a loopback callback), and turns on Add workouts, after which an agent's `log_workout`
/// reaches the workout pull with `added_by`.
@MainActor
@Suite(.enabled(if: apiConfigured, "Set API_URL to run against a local Worker"))
struct AgentsTransportTests {
    private struct Connected {
        let client: ClaudeTestClient
        let clientId: String
        let tokens: ClaudeTestClient.Tokens
    }

    /// Registers an agent named `name`, approves its code with the owner's transport, and returns it with its tokens.
    private func connect(_ name: String, to transport: ApiSyncTransport) async throws -> Connected {
        let agent = ClaudeTestClient(base: try IntegrationEnv.config().baseURL)
        let clientId = try await agent.register(name: name)
        let signIn = try await agent.startSignIn(clientId: clientId)
        try await transport.decideConnect(code: signIn.code, decision: .approve)
        let tokens = try await agent.exchange(signIn, code: try await agent.finish(signIn))
        return Connected(client: agent, clientId: clientId, tokens: tokens)
    }

    @Test func eachAgentIsListedAndDisconnectingOneLeavesTheOther() async throws {
        let user = try await Account.signUp()
        let transport = user.transport
        #expect(try await transport.connectedAgents().isEmpty)
        let claude = try await connect("Claude Code", to: transport)
        let muse = try await connect("Muse", to: transport)

        let listed = try await transport.connectedAgents()
        #expect(listed.map(\.clientId) == [muse.clientId, claude.clientId]) // newest connection first
        #expect(listed.map(\.name) == ["Muse", "Claude Code"])
        #expect(listed.allSatisfy { $0.host == "127.0.0.1:53682" && !$0.knownHost && $0.lastUsedAt == nil })
        #expect(listed.allSatisfy { abs($0.connectedAt.timeIntervalSinceNow) < 120 })

        let read = try await muse.client.callTool(muse.tokens.access, "get_profile")
        #expect(!read.isError, "\(read.json)")
        let used = try await transport.connectedAgents()
        let museUse = try #require(used.first { $0.clientId == muse.clientId }?.lastUsedAt)
        #expect(abs(museUse.timeIntervalSinceNow) < 120)
        #expect(used.first { $0.clientId == claude.clientId }?.lastUsedAt == nil)

        try await transport.disconnectAgent(clientId: muse.clientId)
        #expect(try await muse.client.mcp(muse.tokens.access, method: "tools/list").status == 401)
        let refresh = try await muse.client.refreshStatus(clientId: muse.clientId, refreshToken: muse.tokens.refresh)
        #expect((400..<500).contains(refresh), "refresh after Disconnect answered HTTP \(refresh)")
        #expect(try await claude.client.mcp(claude.tokens.access, method: "tools/list").status == 200)
        #expect(try await transport.connectedAgents().map(\.clientId) == [claude.clientId])
        await #expect(throws: AgentError.unknownAgent) { try await transport.disconnectAgent(clientId: muse.clientId) }

        #expect(try await transport.revokeOAuthGrants() == 1) // Disconnect all: the one left
        #expect(try await transport.connectedAgents().isEmpty)
        try await user.deleteAccount()
    }

    @Test func aProposalSaysWhichAgentSentIt() async throws {
        let user = try await Account.signUp()
        let muse = try await connect("Muse", to: user.transport)
        let proposed = try await muse.client.callTool(muse.tokens.access, "change_plan", [
            "summary": "Add a Pull day",
            "changes": [["id": "c1", "type": "add-routine", "routineId": "new-pull", "name": "Pull"]],
        ])
        #expect(!proposed.isError, "\(proposed.json)")
        let pulled = try await user.transport.pendingProposals()
        guard case .valid(let proposal) = try #require(pulled.first), pulled.count == 1 else {
            Issue.record("expected one valid proposal, got \(pulled)")
            return
        }
        #expect(proposal.fromAgent == "Muse (local)")
        #expect(proposal.toDomain().fromAgent == "Muse (local)")
        try await user.deleteAccount()
    }

    @Test func withAddWorkoutsOnAnAgentsWorkoutIsPulledWithItsName() async throws {
        let user = try await Account.signUp()
        let transport = user.transport
        var profile = ProfileSnapshot()
        profile.mcpLogWorkouts = true
        #expect(try await transport.push(profile: ProfileDTO(SyncRow(value: profile, clientUpdatedAt: Date()))) != nil)
        #expect(try await transport.pullProfile(since: nil).first?.mcpLogWorkouts == true)

        let muse = try await connect("Muse", to: transport)
        let logged = try await muse.client.callTool(muse.tokens.access, "log_workout", ["workouts": [[
            "started_at": "2026-10-08T17:02:00Z", "ended_at": "2026-10-08T18:05:00Z", "name": "Upper",
            "exercises": [["exercise_id": "0025", "sets": [["reps": 8, "weight_kg": 63.5], ["reps": 7, "weight_kg": 63.5]]]],
        ]]])
        #expect(!logged.isError, "\(logged.json)")

        let pulled = try #require(try await transport.pullWorkouts(since: nil).first { $0.name == "Upper" })
        #expect(pulled.addedBy == "Muse (local)")
        #expect(pulled.source == "import")
        #expect(pulled.entries.first?.sets.map(\.r) == [8, 7])
        #expect(pulled.toDomain().value.addedBy == "Muse (local)")
        try await user.deleteAccount()
    }
}
