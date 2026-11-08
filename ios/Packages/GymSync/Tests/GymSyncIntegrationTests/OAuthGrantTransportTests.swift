import Foundation
import Testing
@testable import GymSync

/// Approve a connection and Disconnect Claude against the local Worker: a real OAuth client (`ClaudeTestClient`, what
/// Claude does) registers and opens `/connect`, the owner's transport approves or denies its code, and revoking ends
/// its access token and its refresh token at once (spec section 4, "Claude's connection").
@MainActor
@Suite(.enabled(if: apiConfigured, "Set API_URL to run against a local Worker"))
struct OAuthGrantTransportTests {
    @Test func anApprovedCodeConnectsClaudeAndDisconnectEndsItsTokens() async throws {
        let user = try await Account.signUp()
        let transport = user.transport
        #expect(try await transport.revokeOAuthGrants() == 0) // nothing granted yet
        let claude = ClaudeTestClient(base: try IntegrationEnv.config().baseURL)
        let clientId = try await claude.register()
        let signIn = try await claude.startSignIn(clientId: clientId)

        let request = try await transport.connectRequest(code: signIn.code.lowercased())
        #expect(request.code == signIn.code && request.clientName == "Claude Code")
        #expect(request.redirectHost == "127.0.0.1:53682" && !request.knownHost)
        try await transport.decideConnect(code: signIn.code, decision: .approve)
        await #expect(throws: ConnectCodeError.unknownCode) { // a code works once
            try await transport.decideConnect(code: signIn.code, decision: .deny)
        }
        let tokens = try await claude.exchange(signIn, code: try await claude.finish(signIn))
        #expect(tokens.scope == "mcp offline_access")
        #expect(try await claude.mcp(tokens.access, method: "tools/list").status == 200)

        #expect(try await transport.revokeOAuthGrants() == 1)
        #expect(try await claude.mcp(tokens.access, method: "tools/list").status == 401)
        let refresh = try await claude.refreshStatus(clientId: clientId, refreshToken: tokens.refresh)
        #expect((400..<500).contains(refresh), "refresh after Disconnect answered HTTP \(refresh)")
        try await user.deleteAccount()
    }

    @Test func aDeniedCodeSendsClaudeAccessDenied() async throws {
        let user = try await Account.signUp()
        let claude = ClaudeTestClient(base: try IntegrationEnv.config().baseURL)
        let signIn = try await claude.startSignIn(clientId: try await claude.register())

        try await user.transport.decideConnect(code: signIn.code, decision: .deny)

        let callback = try await claude.denial(signIn)
        #expect(callback.queryItems?.first { $0.name == "error" }?.value == "access_denied")
        #expect(callback.queryItems?.first { $0.name == "state" }?.value == signIn.state)
        try await user.deleteAccount()
    }

    @Test func fiveWrongCodesThenNoMoreTries() async throws {
        let user = try await Account.signUp()
        for _ in 0..<5 {
            await #expect(throws: ConnectCodeError.unknownCode) {
                try await user.transport.connectRequest(code: "ZZZZZZZZ")
            }
        }
        await #expect(throws: ConnectCodeError.tooManyAttempts) {
            try await user.transport.connectRequest(code: "ZZZZZZZZ")
        }
        try await user.deleteAccount()
    }
}
