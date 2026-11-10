import Foundation

/// Claude's side of the API, `/v1/claude` (server/src/claude/routes.ts; spec section 3, "Routes"), behind the app's
/// session like the rest of `/v1`:
/// - `GET /proposals` → `{"rows": [...]}`, the pending ones oldest first, each decoded on its own (`PulledProposal`).
/// - `PATCH /proposals/:id` with the resolution → `{"id", "updated_at"}`. Last-write-wins keeps a newer one, as
///   `lww_guard` did; a refused value is `422 row_rejected`.
/// - `GET /last-use` → `{"at"}`, the newest audit row's time or null.
/// - `POST /revoke` → `{"revoked"}`: Disconnect Claude removes every grant and token of the account.
/// - `GET /connect/:code` and `POST /connect/:code` `{"decision"}`: Approve a connection.
extension ApiSyncTransport {
    public func pendingProposals() async throws -> [PulledProposal] {
        let answer: ProposalRows = try await api.get("/v1/claude/proposals")
        return answer.rows
    }

    /// A proposal the server no longer has (`404 no_such_proposal`) has nothing left to resolve, so the resolution
    /// counts as sent, as an update of no row did on the old server. Added after review: any other 404 (a missing route's
    /// `not_found`, a proxy's `http_404`) is an error, so the engine keeps the resolution to send again.
    public func resolveProposal(id: UUID, status: String, appliedChangeIds: [String], at: Date) async throws {
        let stamp = SyncDate.format(at)
        let body = try SyncJSON.encoder.encode(Resolution(status: status, appliedChangeIds: appliedChangeIds,
                                                          resolvedAt: stamp, clientUpdatedAt: stamp))
        do {
            _ = try await Self.mappingRejections {
                try await api.data("PATCH", "/v1/claude/proposals/\(id.uuidString.lowercased())", body: body)
            }
        } catch let error as ApiError where error.status == 404 && error.code == "no_such_proposal" {
            return
        }
    }

    public func lastMcpUse() async throws -> Date? {
        let answer: LastUse = try await api.get("/v1/claude/last-use")
        return answer.at
    }

    public func revokeOAuthGrants() async throws -> Int {
        let answer: Revoked = try await api.post("/v1/claude/revoke", NoBody())
        return answer.revoked
    }

    public func connectRequest(code: String) async throws -> ConnectRequest {
        try await Self.mappingConnectErrors { try await api.get("/v1/claude/connect/\(code)") }
    }

    public func decideConnect(code: String, decision: ConnectDecision) async throws {
        let _: Decided = try await Self.mappingConnectErrors {
            try await api.post("/v1/claude/connect/\(code)", Decision(decision: decision.rawValue))
        }
    }

    /// The two answers about the code itself; anything else (signed out, offline) stays an `ApiError` or `URLError`.
    static func mappingConnectErrors<R>(_ call: () async throws -> R) async throws -> R {
        do {
            return try await call()
        } catch let error as ApiError where error.code == "unknown_code" {
            throw ConnectCodeError.unknownCode
        } catch let error as ApiError where error.code == "too_many_attempts" {
            throw ConnectCodeError.tooManyAttempts
        }
    }
}

private struct ProposalRows: Decodable {
    let rows: [PulledProposal]
}

/// What the old server's resolveProposal wrote: both times are the resolution's.
private struct Resolution: Encodable {
    let status: String
    let appliedChangeIds: [String]
    let resolvedAt: String
    let clientUpdatedAt: String

    enum CodingKeys: String, CodingKey {
        case status, appliedChangeIds = "applied_change_ids", resolvedAt = "resolved_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

private struct LastUse: Decodable {
    let at: Date?
}

private struct Revoked: Decodable {
    let revoked: Int
}

private struct NoBody: Encodable {}

private struct Decision: Encodable {
    let decision: String
}

private struct Decided: Decodable {
    let status: String
}
