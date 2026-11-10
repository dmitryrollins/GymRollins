import Foundation
import Testing
@testable import GymSync

/// Plan 32: the engine hands Settings › AI agents the server's list and Disconnect for one agent.
@MainActor
@Suite struct SyncEngineAgentsTests {
    let f: EngineFixture
    init() throws { f = try EngineFixture() }

    private static let muse = ConnectedAgent(clientId: "MuseClientIdAbc", name: "Muse", host: "agent.meta.ai",
                                             knownHost: false, connectedAt: t0, lastUsedAt: t0.addingTimeInterval(600))
    private static let claude = ConnectedAgent(clientId: "ClaudeClientIdXyz", name: "Claude", host: "claude.ai",
                                               knownHost: true, connectedAt: t0.addingTimeInterval(-86_400),
                                               lastUsedAt: nil)

    @Test func theListIsTheServersAndDisconnectCutsOnlyThatAgent() async throws {
        defer { f.tearDown() }
        await f.server.seed(agents: [Self.muse, Self.claude])
        #expect(try await f.engine.connectedAgents() == [Self.muse, Self.claude])

        try await f.engine.disconnectAgent(clientId: Self.muse.clientId)
        #expect(try await f.engine.connectedAgents() == [Self.claude])
        await #expect(throws: AgentError.unknownAgent) {
            try await f.engine.disconnectAgent(clientId: Self.muse.clientId)
        }
    }

    @Test func offlineTheListAndDisconnectFailAndNothingGoes() async throws {
        defer { f.tearDown() }
        await f.server.seed(agents: [Self.muse])
        await f.server.fail(with: URLError(.notConnectedToInternet))
        await #expect(throws: URLError.self) { try await f.engine.connectedAgents() }
        await #expect(throws: URLError.self) { try await f.engine.disconnectAgent(clientId: Self.muse.clientId) }
        #expect(await f.server.agents == [Self.muse])
    }
}
