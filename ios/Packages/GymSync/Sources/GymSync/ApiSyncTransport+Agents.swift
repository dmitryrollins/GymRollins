import Foundation

/// The agents connected to the account (plan 32, spec section 3), behind the app's session like the rest of `/v1`:
/// - `GET /v1/agents` → `{"agents": [...]}`, newest connection first.
/// - `POST /v1/agents/:clientId/disconnect` → `{"disconnected": true}`, or `404 unknown_agent` when the account has
///   no grant for that client. Every other agent keeps its access; `POST /v1/claude/revoke` stays as Disconnect all.
extension ApiSyncTransport {
    public func connectedAgents() async throws -> [ConnectedAgent] {
        let answer: AgentList = try await api.get("/v1/agents")
        return answer.agents
    }

    public func disconnectAgent(clientId: String) async throws {
        guard Self.isClientId(clientId) else { throw AgentError.unknownAgent }
        do {
            let _: Disconnected = try await api.post("/v1/agents/\(clientId)/disconnect", NothingToSend())
        } catch let error as ApiError where error.status == 404 && error.code == "unknown_agent" {
            throw AgentError.unknownAgent
        }
    }

    /// The id goes into the URL path, so only what a client id is made of is sent: ASCII letters (Better Auth's are
    /// 32 of them), digits, `-` and `_`, at most 128. Anything else names no agent of this account.
    static func isClientId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

private struct AgentList: Decodable {
    let agents: [ConnectedAgent]
}

private struct Disconnected: Decodable {
    let disconnected: Bool
}

private struct NothingToSend: Encodable {}
