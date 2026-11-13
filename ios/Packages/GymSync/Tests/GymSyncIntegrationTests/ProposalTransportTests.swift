import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// Claude's proposals and last use on the local Worker, read and resolved as the app does: Claude (a real OAuth client,
/// `ClaudeTestClient`) proposes through `/mcp`, the owner's transport pulls and resolves it, and Claude then sees it
/// applied. A row the app can't read is covered by `ApiClaudeTransportTests` (the server's tools never write one).
@MainActor
@Suite(.enabled(if: apiConfigured, "Set API_URL to run against a local Worker"))
struct ProposalTransportTests {
    @Test func aProposalFromClaudeIsPulledResolvedAndSeenApplied() async throws {
        let user = try await Account.signUp()
        let transport = user.transport
        #expect(try await transport.lastMcpUse() == nil)
        let claude = ClaudeTestClient(base: try IntegrationEnv.config().baseURL)
        let tokens = try await claude.connect { code in
            try await transport.decideConnect(code: code, decision: .approve)
        }

        let proposed = try await claude.callTool(tokens.access, "change_plan", [
            "summary": "Add a Push day",
            "changes": [["id": "c1", "type": "add-routine", "routineId": "new-push", "name": "Push"]],
        ])
        #expect(!proposed.isError)
        let pulled = try await transport.pendingProposals()
        guard case .valid(let proposal) = try #require(pulled.first), pulled.count == 1 else {
            Issue.record("expected one valid proposal, got \(pulled)")
            return
        }
        #expect(proposal.summary == "Add a Push day" && proposal.source == "claude")
        #expect(proposal.changes.first?.type == .addRoutine && proposal.toDomain().status == .pending)

        try await transport.resolveProposal(id: proposal.id, status: "applied", appliedChangeIds: ["c1"],
                                            at: max(Date(), proposal.createdAt))
        #expect(try await transport.pendingProposals().isEmpty)
        let seen = try await claude.callTool(tokens.access, "get_plan_change", ["id": proposal.id.uuidString.lowercased()])
        #expect(seen.json["status"] as? String == "applied")
        #expect(seen.json["applied_change_ids"] as? [String] == ["c1"])

        let last = try #require(try await transport.lastMcpUse())
        #expect(abs(last.timeIntervalSinceNow) < 120)
        try await user.deleteAccount()
    }

    @Test func anOlderResolutionLeavesTheNewerOne() async throws {
        let user = try await Account.signUp()
        let transport = user.transport
        let claude = ClaudeTestClient(base: try IntegrationEnv.config().baseURL)
        let tokens = try await claude.connect { code in
            try await transport.decideConnect(code: code, decision: .approve)
        }
        _ = try await claude.callTool(tokens.access, "change_plan", [
            "summary": "Add a Pull day",
            "changes": [["id": "c1", "type": "add-routine", "routineId": "new-pull", "name": "Pull"]],
        ])
        // Added after review: a row that isn't valid fails the test, instead of passing it without a check.
        let pulled = try #require(try await transport.pendingProposals().first)
        guard case .valid(let proposal) = pulled else {
            Issue.record("expected a valid proposal, got \(pulled)")
            return
        }
        let later = max(Date(), proposal.createdAt).addingTimeInterval(60)
        try await transport.resolveProposal(id: proposal.id, status: "dismissed", appliedChangeIds: [], at: later)
        try await transport.resolveProposal(id: proposal.id, status: "applied", appliedChangeIds: ["c1"],
                                            at: later.addingTimeInterval(-30))
        let seen = try await claude.callTool(tokens.access, "get_plan_change", ["id": proposal.id.uuidString.lowercased()])
        #expect(seen.json["status"] as? String == "dismissed")
        try await user.deleteAccount()
    }

    /// Added after review: the Worker's answer for a proposal it doesn't have (`no_such_proposal`) is the one 404 the
    /// app counts as sent.
    @Test func aResolutionOfAProposalTheServerLacksCountsAsSent() async throws {
        let user = try await Account.signUp()
        try await user.transport.resolveProposal(id: UUID(), status: "dismissed", appliedChangeIds: [], at: Date())
        try await user.deleteAccount()
    }
}
