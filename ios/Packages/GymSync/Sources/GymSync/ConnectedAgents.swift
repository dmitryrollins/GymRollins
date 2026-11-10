import Foundation

/// One agent connected to the account, as Settings › AI agents lists it (`GET /v1/agents`, plan 32): an OAuth client
/// that holds this account's consent or a live refresh token. The server lists them newest connection first.
public struct ConnectedAgent: Decodable, Equatable, Sendable, Identifiable {
    public let clientId: String
    /// The name it registered with (at most 64 characters), or its host when it gave none. Chosen by the agent: shown
    /// as plain text only.
    public let name: String
    /// The host of its first redirect URL: `claude.ai`, `agent.meta.ai`, or `127.0.0.1:53682` for a loopback one.
    public let host: String
    /// True for Claude's own hosts (claude.ai, claude.com), as on the approve sheet.
    public let knownHost: Bool
    public let connectedAt: Date
    /// Its newest MCP call for this account; nil before the first.
    public let lastUsedAt: Date?

    public var id: String { clientId }

    public init(clientId: String, name: String, host: String, knownHost: Bool, connectedAt: Date, lastUsedAt: Date?) {
        self.clientId = clientId
        self.name = name
        self.host = host
        self.knownHost = knownHost
        self.connectedAt = connectedAt
        self.lastUsedAt = lastUsedAt
    }

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id", name, host, knownHost = "known_host", connectedAt = "connected_at"
        case lastUsedAt = "last_used_at"
    }
}

/// Why Disconnect couldn't act on an agent.
public enum AgentError: Error, Equatable, Sendable {
    /// The account has no grant for this client (`404 unknown_agent`), or the id can't be a client id: it is already
    /// disconnected, or was never connected.
    case unknownAgent
}
