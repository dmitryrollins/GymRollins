import Foundation
import GymSync
import Observation

/// The calls behind Settings › AI agents' Connected agents (plan 32): the account's through the sync coordinator
/// (`AppEnvironment.agentCalls`), or DEBUG's in-memory list under `-fakeAgents`. Passed in on each call, so the tests
/// run `AgentsModel` without a server.
struct AgentCalls {
    typealias List = @MainActor () async throws -> [ConnectedAgent]
    typealias Disconnect = @MainActor (String) async throws -> Void

    let list: List
    let disconnect: Disconnect
}

/// What Connected agents shows, apart from how it looks (spec section 4): the account's agents as the server lists
/// them, newest connection first; the one line shown while there's no row; and what a Disconnect leaves.
@MainActor @Observable
final class AgentsModel {
    enum Phase: Equatable {
        case loading
        case loaded([ConnectedAgent])
        /// The first load failed, with the words to show.
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    /// The agent whose Disconnect is on its way; its button is disabled meanwhile.
    private(set) var disconnecting: String?
    /// Why the last Disconnect, or a reload of a list already shown, didn't work.
    private(set) var error: String?
    /// Moves on with each load and each Disconnect that removed a row. A load whose answer arrives after it moved on
    /// (a newer load, or a Disconnect) is stale, and would put a disconnected agent back (added after review).
    private var revision = 0

    var agents: [ConnectedAgent] {
        if case .loaded(let agents) = phase { return agents }
        return []
    }

    /// The line shown in place of rows (`claude.status`); nil while there are rows.
    var statusText: String? {
        switch phase {
        case .loading: "Checking\u{2026}"
        case .loaded(let agents): agents.isEmpty ? AgentText.none : nil
        case .failed(let message): message
        }
    }

    /// Asks for the list. A failed reload keeps the rows already shown and says why below them; a stale answer is
    /// dropped.
    func load(_ calls: AgentCalls) async {
        revision += 1
        let asked = revision
        do {
            let listed = try await calls.list()
            if Task.isCancelled || asked != revision { return }
            phase = .loaded(listed)
            error = nil
        } catch {
            if Task.isCancelled || asked != revision { return }
            let message = Self.loadMessage(for: error)
            if case .loaded = phase {
                self.error = message
            } else {
                phase = .failed(message)
            }
        }
    }

    /// Disconnects one agent, after its row's confirmation. Only it goes; one the server no longer has goes too
    /// (decision A6). A cancelled request may or may not have reached the server, so the list is asked again (added
    /// after review). Any other failure keeps the row and says the agent still has access.
    func disconnect(_ agent: ConnectedAgent, _ calls: AgentCalls) async {
        guard disconnecting == nil else { return }
        disconnecting = agent.clientId
        error = nil
        defer { disconnecting = nil }
        do {
            try await calls.disconnect(agent.clientId)
            removeRow(agent)
        } catch AgentError.unknownAgent {
            removeRow(agent)
        } catch let error where Self.isCancellation(error) {
            await load(calls)
        } catch {
            self.error = Self.disconnectMessage(for: error, name: agent.name)
        }
    }

    private func removeRow(_ agent: ConnectedAgent) {
        revision += 1
        phase = .loaded(agents.filter { $0.clientId != agent.clientId })
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    static func loadMessage(for error: Error) -> String {
        if error is SyncUnavailableError { return "Sign in to GymRollins to see your agents." }
        if let api = error as? ApiError, api.status == 401 { return "Sign in to GymRollins to see your agents." }
        return ApiError.isOffline(error)
            ? "Couldn't reach GymRollins to list your agents. Check your connection and try again."
            : "Couldn't load your agents. Try again."
    }

    static func disconnectMessage(for error: Error, name: String) -> String {
        switch error {
        case is SyncUnavailableError:
            "Sign in to GymRollins first, with the account \(name) uses."
        case let api as ApiError where api.status == 401:
            "Sign in to GymRollins first, with the account \(name) uses."
        default:
            ApiError.isOffline(error)
                ? "Couldn't reach GymRollins, so \(name) still has access. Check your connection and try again."
                : "Couldn't disconnect \(name), so it still has access. Try again."
        }
    }
}

/// The words the agents' screens share (plan 32). Agent names come from the agent: they go into `Text` as plain
/// `String`s, never as Markdown.
enum AgentText {
    static let none = "No agents connected."

    /// "Last used 2 min ago", in Account's sync wording (`SyncStatusText.lastSynced`), or "Not used yet".
    static func lastUsed(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not used yet" }
        let when = SyncStatusText.lastSynced(date, now: now)
        return "Last used " + (when == "Just now" ? "just now" : when)
    }

    static func confirmDisconnect(_ name: String) -> String {
        "Disconnect \(name)? It loses access until you approve it again."
    }

    static func disconnectLabel(_ name: String) -> String { "Disconnect \(name)" }

    static func from(_ name: String) -> String { "From \(name)" }

    static func addedBy(_ name: String) -> String { "Added by \(name)" }

    /// A proposal row's second line: the parts joined with " · ", leaving out a sender the server didn't know.
    static func caption(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}
