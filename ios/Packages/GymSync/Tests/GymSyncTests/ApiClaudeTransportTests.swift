import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// `ApiSyncTransport` against a stub of `/v1/claude`: the paths, bodies and answers of server/src/claude/routes.ts.
@Suite struct ApiClaudeTransportTests {
    private let proposalId = UUID()

    private func proposalJSON(type: String = "weight") -> String {
        #"{"id": "\#(proposalId.uuidString.lowercased())", "created_at": "2026-11-08T10:00:00.123000Z", "#
            + #""source": "claude", "summary": "Heavier bench", "#
            + #""changes": [{"id": "c1", "type": "\#(type)", "routineId": "r1", "exerciseId": "0025", "#
            + #""weightKg": 65}], "#
            + #""status": "pending", "applied_change_ids": [], "resolved_at": null}"#
    }

    @Test func pendingProposalsComeFromTheClaudeRoutesOneRowAtATime() async throws {
        let rows = #"{"rows": [\#(proposalJSON()), \#(proposalJSON(type: "teleport"))]}"#
        let server = StubServer { _ in .json(200, rows) }

        let pulled = try await ApiSyncTransport(api: server.client()).pendingProposals()

        let request = try #require(server.requests.first)
        #expect(request.method == "GET" && request.path == "/v1/claude/proposals")
        guard case .valid(let dto) = pulled.first else { Issue.record("first row not valid"); return }
        #expect(dto.id == proposalId && dto.changes.first?.weightKg == 65 && dto.toDomain().status == .pending)
        guard case .malformed(let bad) = pulled.last else { Issue.record("second row not malformed"); return }
        #expect(bad.id == proposalId.uuidString.lowercased())
    }

    @Test func aResolutionIsPatchedWithBothTimesAsTheResolutions() async throws {
        let server = StubServer { _ in .json(200, #"{"id": "x", "updated_at": "2026-11-08T10:00:01.000000Z"}"#) }
        let at = SyncDate.parse("2026-11-08T10:00:00.654321Z")!

        try await ApiSyncTransport(api: server.client())
            .resolveProposal(id: proposalId, status: "partial", appliedChangeIds: ["c1"], at: at)

        let request = try #require(server.requests.first)
        #expect(request.method == "PATCH")
        #expect(request.path == "/v1/claude/proposals/\(proposalId.uuidString.lowercased())")
        let body = try #require(try request.json() as? [String: Any])
        #expect(body["status"] as? String == "partial")
        #expect(body["applied_change_ids"] as? [String] == ["c1"])
        #expect(body["resolved_at"] as? String == "2026-11-08T10:00:00.654321Z")
        #expect(body["client_updated_at"] as? String == "2026-11-08T10:00:00.654321Z")
    }

    @Test func aRefusedResolutionIsAboutThatProposalAndAGoneOneCountsAsSent() async throws {
        let refused = StubServer { _ in
            .json(422, #"{"error": {"code": "row_rejected", "message": "status: must be applied or dismissed"}}"#)
        }
        await #expect(throws: SyncRecordRejected.self) {
            try await ApiSyncTransport(api: refused.client())
                .resolveProposal(id: proposalId, status: "pending", appliedChangeIds: [], at: Date())
        }
        let gone = StubServer { _ in
            .json(404, #"{"error": {"code": "no_such_proposal", "message": "No such proposal."}}"#)
        }
        try await ApiSyncTransport(api: gone.client())
            .resolveProposal(id: proposalId, status: "applied", appliedChangeIds: ["c1"], at: Date())
    }

    /// Added after review: only the server's `no_such_proposal` says the proposal is gone. A missing route (an older
    /// or misrouted Worker) or a proxy's page is an error, so the engine keeps the resolution to send again.
    @Test func anyOther404IsAnErrorThatKeepsTheResolution() async throws {
        let noRoute = StubServer { _ in .json(404, #"{"error": {"code": "not_found", "message": "No such route."}}"#) }
        await #expect(throws: ApiError(status: 404, code: "not_found", message: "No such route.")) {
            try await ApiSyncTransport(api: noRoute.client())
                .resolveProposal(id: proposalId, status: "applied", appliedChangeIds: ["c1"], at: Date())
        }
        let proxy = StubServer { _ in
            StubAnswer(status: 404, headers: ["Content-Type": "text/html"], body: Data("<h1>Not Found</h1>".utf8))
        }
        await #expect(throws: ApiError.self) {
            try await ApiSyncTransport(api: proxy.client())
                .resolveProposal(id: proposalId, status: "applied", appliedChangeIds: ["c1"], at: Date())
        }
    }

    @Test func lastUseIsNilUntilClaudeCallsATool() async throws {
        let never = StubServer { _ in .json(200, #"{"at": null}"#) }
        #expect(try await ApiSyncTransport(api: never.client()).lastMcpUse() == nil)
        let once = StubServer { _ in .json(200, #"{"at": "2026-11-08T05:44:54.223000Z"}"#) }
        #expect(try await ApiSyncTransport(api: once.client()).lastMcpUse()
            == SyncDate.parse("2026-11-08T05:44:54.223Z"))
        #expect(once.requests.first?.path == "/v1/claude/last-use")
    }

    @Test func disconnectPostsTheRevokeAndCountsWhatWent() async throws {
        let server = StubServer { _ in .json(200, #"{"revoked": 1}"#) }

        #expect(try await ApiSyncTransport(api: server.client()).revokeOAuthGrants() == 1)
        let request = try #require(server.requests.first)
        #expect(request.method == "POST" && request.path == "/v1/claude/revoke")
    }

    @Test func aCodeLooksUpItsWaitingSignIn() async throws {
        let answer = #"{"code": "ABCD-EFGH", "client_name": "Claude", "redirect_host": "claude.ai", "#
            + #""known_host": true, "expires_at": "2026-11-08T10:10:00.000000Z", "#
            + #""opened_at": "2026-11-08T10:00:00.000000Z", "country": "CA", "city": "Toronto", "#
            + #""user_agent": null}"#
        let server = StubServer { _ in .json(200, answer) }

        let request = try await ApiSyncTransport(api: server.client()).connectRequest(code: "ABCDEFGH")

        #expect(request == ConnectRequest(code: "ABCD-EFGH", clientName: "Claude", redirectHost: "claude.ai",
                                          knownHost: true, expiresAt: SyncDate.parse("2026-11-08T10:10:00Z")!,
                                          openedAt: SyncDate.parse("2026-11-08T10:00:00Z")!, country: "CA",
                                          city: "Toronto", userAgent: nil))
        #expect(server.requests.first?.path == "/v1/claude/connect/ABCDEFGH")
    }

    @Test func aDecisionIsPostedForTheCode() async throws {
        let server = StubServer { _ in .json(200, #"{"status": "denied"}"#) }

        try await ApiSyncTransport(api: server.client()).decideConnect(code: "ABCDEFGH", decision: .deny)

        let request = try #require(server.requests.first)
        #expect(request.method == "POST" && request.path == "/v1/claude/connect/ABCDEFGH")
        #expect((try request.json() as? [String: String]) == ["decision": "deny"])
    }

    @Test func aWrongCodeAndTooManyTriesSaySo() async throws {
        let unknown = StubServer { _ in
            .json(404, #"{"error": {"code": "unknown_code", "message": "No waiting request has this code."}}"#)
        }
        await #expect(throws: ConnectCodeError.unknownCode) {
            try await ApiSyncTransport(api: unknown.client()).connectRequest(code: "ZZZZZZZZ")
        }
        let limited = StubServer { _ in
            .json(429, #"{"error": {"code": "too_many_attempts", "message": "Too many wrong codes."}}"#)
        }
        await #expect(throws: ConnectCodeError.tooManyAttempts) {
            try await ApiSyncTransport(api: limited.client()).decideConnect(code: "ZZZZZZZZ", decision: .approve)
        }
        let signedOut = StubServer { _ in .json(401, #"{"error": {"code": "signed_out", "message": "Sign in."}}"#) }
        await #expect(throws: ApiError.self) {
            try await ApiSyncTransport(api: signedOut.client()).connectRequest(code: "ZZZZZZZZ")
        }
    }
}

@Suite struct ConnectCodeTests {
    @Test func whatIsTypedBecomesCodeCharacters() {
        #expect(ConnectCode.characters(of: "abcd-efgh") == "ABCDEFGH")
        #expect(ConnectCode.characters(of: " 7k2m 9pqr ") == "7K2M9PQR")
        #expect(ConnectCode.characters(of: "OIL0-1234") == "01101234")
        #expect(ConnectCode.characters(of: "ab-cd\tef gh\n") == "ABCDEFGH")
        #expect(ConnectCode.characters(of: "") == "")
    }

    /// Added after review: a character outside the alphabet makes the text no code at all. Dropping it would turn
    /// "Code: ABCD-EFGH" into C0DEABCD, sent and using a try; `ß` would upper-case to "SS".
    @Test func anythingElseIsRefusedNotDropped() {
        #expect(ConnectCode.characters(of: "UUAB") == nil)
        #expect(ConnectCode.characters(of: "Code: ABCD-EFGH") == nil)
        #expect(ConnectCode.characters(of: "ABCDEFß") == nil)
        #expect(ConnectCode.characters(of: "ABCD_EFGH") == nil)
        #expect(ConnectCode.characters(of: "ABCD\u{2013}EFGH") == nil) // an en dash
        #expect(ConnectCode.characters(of: "\u{FF21}BCDEFGH") == nil) // a full-width A
        #expect(ConnectCode.complete("Code: ABCD-EFGH") == nil)
        #expect(ConnectCode.complete("ABCDEFß") == nil && ConnectCode.complete("ABCDEFGß") == nil)
        #expect(ConnectCode.isInvalid("Code: ABCD-EFGH") && ConnectCode.isInvalid("ABCDEFß"))
        #expect(!ConnectCode.isInvalid("abcd-ef") && !ConnectCode.isInvalid(""))
    }

    /// Added after review: a ninth character is too many, never cut off to a code nobody showed.
    @Test func moreThanEightIsNoCode() {
        #expect(ConnectCode.complete("ABCDEFGHJK") == nil)
        #expect(ConnectCode.isInvalid("ABCDEFGHJ"))
        #expect(ConnectCode.display("abcdefghjk") == "ABCD-EFGHJK")
    }

    @Test func itShowsTheDashAfterFour() {
        #expect(ConnectCode.display("ab") == "AB")
        #expect(ConnectCode.display("abcd") == "ABCD")
        #expect(ConnectCode.display("abcde") == "ABCD-E")
        #expect(ConnectCode.display("ABCD-EFGH") == "ABCD-EFGH")
        #expect(ConnectCode.display("ab cd-efgh") == "ABCD-EFGH")
    }

    /// Added after review: what isn't a code is shown as typed, so the owner sees what to fix.
    @Test func whatIsNoCodeIsShownAsTyped() {
        #expect(ConnectCode.display("Code: ABCD-EFGH") == "Code: ABCD-EFGH")
        #expect(ConnectCode.display("abcdß") == "abcdß")
    }

    @Test func itIsCompleteAtEight() {
        #expect(ConnectCode.complete("ABCD-EFG") == nil)
        #expect(ConnectCode.complete("abcd-efgh") == "ABCDEFGH")
        #expect(ConnectCode.complete(" o1l2-3456 ") == "01123456")
    }
}
