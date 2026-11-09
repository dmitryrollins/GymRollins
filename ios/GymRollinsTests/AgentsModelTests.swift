import Foundation
import GymSync
import Testing
@testable import GymRollins

/// Connected agents without a server (plan 32): what the list shows, the line in place of rows, and what Disconnect
/// leaves.
@MainActor
@Suite struct AgentsModelTests {
    private static let now = Date(timeIntervalSince1970: 1_790_413_200) // Sat 26 Sep 2026, 09:00 UTC
    private static let muse = ConnectedAgent(clientId: "MuseClientIdAbc", name: "Muse", host: "agent.meta.ai",
                                             knownHost: false, connectedAt: now - 86_400, lastUsedAt: now - 7_200)
    private static let claude = ConnectedAgent(clientId: "ClaudeClientIdXyz", name: "Claude", host: "claude.ai",
                                               knownHost: true, connectedAt: now - 6 * 86_400, lastUsedAt: nil)

    /// A server for one test: the list it answers (or the error it throws), and the agents it was asked to disconnect.
    @MainActor private final class Server {
        var listed: Result<[ConnectedAgent], any Error> = .success([])
        var refusal: (any Error)?
        private(set) var disconnected: [String] = []

        var calls: AgentCalls {
            AgentCalls(list: { [self] in try listed.get() }, disconnect: { [self] id in
                if let refusal { throw refusal }
                disconnected.append(id)
            })
        }
    }

    private func loaded(_ agents: [ConnectedAgent]) async -> (AgentsModel, Server) {
        let server = Server()
        server.listed = .success(agents)
        let model = AgentsModel()
        await model.load(server.calls)
        return (model, server)
    }

    @Test func itSaysItIsCheckingUntilTheFirstAnswer() {
        let model = AgentsModel()
        #expect(model.statusText == "Checking\u{2026}")
        #expect(model.agents.isEmpty && model.error == nil)
    }

    @Test func theAgentsAreTheServersInItsOrder() async {
        let (model, _) = await loaded([Self.muse, Self.claude])
        #expect(model.agents == [Self.muse, Self.claude])
        #expect(model.statusText == nil && model.error == nil)
    }

    @Test func noAgentsSaysSo() async {
        let (model, _) = await loaded([])
        #expect(model.statusText == "No agents connected.")
    }

    @Test func aFirstLoadThatFailsSaysWhy() async {
        let model = AgentsModel()
        let server = Server()
        server.listed = .failure(URLError(.notConnectedToInternet))
        await model.load(server.calls)
        #expect(model.statusText
            == "Couldn't reach GymRollins to list your agents. Check your connection and try again.")
        server.listed = .failure(ApiError(status: 403, code: "forbidden", message: "No."))
        await model.load(server.calls)
        #expect(model.statusText == "Couldn't load your agents. Try again.")
        server.listed = .failure(ApiError(status: 401, code: "signed_out", message: "Sign in."))
        await model.load(server.calls)
        #expect(model.statusText == "Sign in to GymRollins to see your agents.")
        #expect(model.agents.isEmpty)
    }

    @Test func aReloadThatFailsKeepsTheRowsAndSaysWhyBelowThem() async {
        let (model, server) = await loaded([Self.muse])
        server.listed = .failure(URLError(.timedOut))
        await model.load(server.calls)
        #expect(model.agents == [Self.muse] && model.statusText == nil)
        #expect(model.error == "Couldn't reach GymRollins to list your agents. Check your connection and try again.")
        server.listed = .success([Self.muse])
        await model.load(server.calls)
        #expect(model.error == nil)
    }

    @Test func disconnectCutsOnlyThatAgent() async {
        let (model, server) = await loaded([Self.muse, Self.claude])
        await model.disconnect(Self.muse, server.calls)
        #expect(server.disconnected == ["MuseClientIdAbc"])
        #expect(model.agents == [Self.claude])
        #expect(model.error == nil && model.disconnecting == nil)
        await model.disconnect(Self.claude, server.calls)
        #expect(model.statusText == "No agents connected.")
    }

    @Test func anAgentTheServerNoLongerHasGoesToo() async {
        let (model, server) = await loaded([Self.muse, Self.claude])
        server.refusal = AgentError.unknownAgent
        await model.disconnect(Self.muse, server.calls)
        #expect(model.agents == [Self.claude] && model.error == nil)
    }

    @Test func aDisconnectThatFailsKeepsTheAgentAndSaysItStillHasAccess() async {
        let (model, server) = await loaded([Self.muse, Self.claude])
        let offline = "Couldn't reach GymRollins, so Muse still has access. Check your connection and try again."
        let signIn = "Sign in to GymRollins first, with the account Muse uses."
        let cases: [(any Error, String)] = [
            (URLError(.notConnectedToInternet), offline),
            (ApiError(status: 503, code: "http_503", message: "Busy."), offline),
            (ApiError(status: 403, code: "forbidden", message: "No."),
             "Couldn't disconnect Muse, so it still has access. Try again."),
            (ApiError(status: 401, code: "signed_out", message: "Sign in."), signIn),
            (SyncUnavailableError(), signIn),
        ]
        for (refusal, words) in cases {
            server.refusal = refusal
            await model.disconnect(Self.muse, server.calls)
            #expect(model.agents == [Self.muse, Self.claude])
            #expect(model.error == words)
            #expect(model.disconnecting == nil)
        }
        #expect(server.disconnected.isEmpty)
    }

    @Test func theRowsWords() {
        let now = Self.now
        #expect(AgentText.lastUsed(nil, now: now) == "Not used yet")
        #expect(AgentText.lastUsed(now, now: now) == "Last used just now")
        #expect(AgentText.lastUsed(now - 120, now: now) == "Last used 2 min ago")
        #expect(AgentText.lastUsed(now - 3 * 3_600, now: now) == "Last used 3 h ago")
        #expect(AgentText.confirmDisconnect("Muse") == "Disconnect Muse? It loses access until you approve it again.")
        #expect(AgentText.disconnectLabel("Muse") == "Disconnect Muse")
        #expect(AgentText.from("Muse") == "From Muse")
        #expect(AgentText.addedBy("Muse") == "Added by Muse")
        #expect(AgentText.none == "No agents connected.")
    }

    /// A proposal row's second line: the parts joined with " · ", leaving out a sender the server didn't know.
    @Test func aProposalsCaptionNamesItsSenderWhenKnown() {
        #expect(AgentText.caption(["25 Sep", AgentText.from("Muse"), "Review"]) == "25 Sep \u{00B7} From Muse \u{00B7} Review")
        #expect(AgentText.caption(["25 Sep", nil, "Review"]) == "25 Sep \u{00B7} Review")
        #expect(AgentText.caption(["Applied", nil]) == "Applied")
    }
}
