import Foundation
import GymCore
import GymData
import Supabase
import Testing
@testable import GymSync

/// Proposals and the MCP audit read over the real local stack, as the owner (not an MCP client).
@MainActor
@Suite(.enabled(if: supabaseConfigured, "Set SUPABASE_URL and SUPABASE_ANON_KEY to run against local Supabase"))
struct ProposalTransportTests {
    private struct NewProposal: Encodable {
        let summary: String
        let changes: [PlanChange]
    }

    private struct StatusRow: Decodable {
        let status: String
        let applied_change_ids: [String] // swiftlint:disable:this identifier_name
    }

    @Test func pendingResolveAndLastUse() async throws {
        let user = try await Account.signUp()
        let transport = user.transport
        let client = user.auth.client
        let routineId = UUID()
        try await client.from("proposals").insert(NewProposal(summary: "Heavier bench", changes: [
            PlanChange(id: "c1", type: .weight, routineId: routineId.uuidString.lowercased(), exerciseId: "0025",
                       weightKg: 65),
        ])).execute()

        // A row the app can't read (unknown change type) comes back malformed; the valid one still decodes.
        try await client.from("proposals").insert([
            "summary": AnyJSON.string("From the future"),
            "changes": .array([.object(["id": .string("c1"), "type": .string("teleport")])]),
        ]).execute()

        let pulled = try await transport.pendingProposals()
        let pending = pulled.compactMap { if case .valid(let dto) = $0 { dto } else { nil } }
        let malformed = pulled.compactMap { if case .malformed(let bad) = $0 { bad } else { nil } }
        #expect(malformed.count == 1 && malformed.first?.message.contains("changes") == true)
        let proposal = try #require(pending.first)
        #expect(pending.count == 1 && proposal.changes.first?.weightKg == 65)
        #expect(proposal.toDomain().status == .pending)

        try await transport.resolveProposal(id: proposal.id, status: "applied", appliedChangeIds: ["c1"],
                                            at: max(Date(), proposal.createdAt))
        #expect(try await transport.pendingProposals().count == 1) // only the malformed one is left
        let row: [StatusRow] = try await client.from("proposals").select("status,applied_change_ids")
            .eq("id", value: proposal.id.uuidString.lowercased()).execute().value
        #expect(row.first?.status == "applied" && row.first?.applied_change_ids == ["c1"])

        #expect(try await transport.lastMcpUse() == nil)
        try await client.from("mcp_audit").insert(["tool": AnyJSON.string("get_plan"), "ok": .bool(true)]).execute()
        let last = try #require(try await transport.lastMcpUse())
        #expect(abs(last.timeIntervalSinceNow) < 120)

        try await user.deleteAccount()
    }
}
