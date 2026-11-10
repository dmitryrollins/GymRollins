import Foundation
import Testing
@testable import GymSync

/// `ApiSyncTransport` against a stub of `/v1/agents` (plan 32, spec section 3): the list as the server answers it,
/// and Disconnect for one agent.
@Suite struct ApiAgentsTransportTests {
    private static let museJSON = #"{"client_id": "MuseClientIdAbc", "name": "Muse", "host": "agent.meta.ai", "#
        + #""known_host": false, "connected_at": "2026-11-09T01:20:00.000000Z", "#
        + #""last_used_at": "2026-11-09T01:31:12.000000Z"}"#
    private static let claudeJSON = #"{"client_id": "ClaudeClientIdXyz", "name": "Claude", "host": "claude.ai", "#
        + #""known_host": true, "connected_at": "2026-11-01T10:00:00.000000Z", "last_used_at": null}"#

    @Test func theListIsEachAgentInTheServersOrder() async throws {
        let server = StubServer { _ in .json(200, #"{"agents": [\#(Self.museJSON), \#(Self.claudeJSON)]}"#) }

        let agents = try await ApiSyncTransport(api: server.client()).connectedAgents()

        let request = try #require(server.requests.first)
        #expect(request.method == "GET" && request.path == "/v1/agents")
        #expect(agents == [
            ConnectedAgent(clientId: "MuseClientIdAbc", name: "Muse", host: "agent.meta.ai", knownHost: false,
                           connectedAt: SyncDate.parse("2026-11-09T01:20:00Z")!,
                           lastUsedAt: SyncDate.parse("2026-11-09T01:31:12Z")),
            ConnectedAgent(clientId: "ClaudeClientIdXyz", name: "Claude", host: "claude.ai", knownHost: true,
                           connectedAt: SyncDate.parse("2026-11-01T10:00:00Z")!, lastUsedAt: nil),
        ])
        #expect(agents.map(\.id) == ["MuseClientIdAbc", "ClaudeClientIdXyz"])
    }

    @Test func noAgentsIsAnEmptyList() async throws {
        let server = StubServer { _ in .json(200, #"{"agents": []}"#) }
        #expect(try await ApiSyncTransport(api: server.client()).connectedAgents().isEmpty)
    }

    @Test func disconnectPostsForThatAgentOnly() async throws {
        let server = StubServer { _ in .json(200, #"{"disconnected": true}"#) }

        try await ApiSyncTransport(api: server.client()).disconnectAgent(clientId: "MuseClientIdAbc")

        let request = try #require(server.requests.first)
        #expect(request.method == "POST" && request.path == "/v1/agents/MuseClientIdAbc/disconnect")
        #expect(server.requests.count == 1)
    }

    /// Only the server's `unknown_agent` says the account has no grant for it. A missing route (an older Worker) or a
    /// proxy's page stays an error.
    @Test func anAgentTheAccountDoesntHaveIsUnknown() async throws {
        let unknown = StubServer { _ in
            .json(404, #"{"error": {"code": "unknown_agent", "message": "No such agent."}}"#)
        }
        await #expect(throws: AgentError.unknownAgent) {
            try await ApiSyncTransport(api: unknown.client()).disconnectAgent(clientId: "MuseClientIdAbc")
        }
        let noRoute = StubServer { _ in .json(404, #"{"error": {"code": "not_found", "message": "No such route."}}"#) }
        await #expect(throws: ApiError(status: 404, code: "not_found", message: "No such route.")) {
            try await ApiSyncTransport(api: noRoute.client()).disconnectAgent(clientId: "MuseClientIdAbc")
        }
    }

    /// The id goes into the URL path, so only the characters a client id is made of are ever sent.
    @Test func anIdThatCantBeAClientIdIsNeverSent() async throws {
        let server = StubServer { _ in .json(200, #"{"disconnected": true}"#) }
        for id in ["", "../claude/revoke", "a/b", "Muse Client", "mus\u{00E9}", "a?b=c", String(repeating: "a", count: 129)] {
            await #expect(throws: AgentError.unknownAgent) {
                try await ApiSyncTransport(api: server.client()).disconnectAgent(clientId: id)
            }
        }
        #expect(server.requests.isEmpty)
        try await ApiSyncTransport(api: server.client()).disconnectAgent(clientId: "Abc_def-123")
        #expect(server.requests.count == 1)
    }
}
