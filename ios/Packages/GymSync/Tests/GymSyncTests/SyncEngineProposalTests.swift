import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymSync

@MainActor
@Suite struct SyncEngineProposalTests {
    let f: EngineFixture
    let engine: SyncEngine
    let push = Routine(name: "Push", exercises: [RoutineExercise(exerciseId: "bench", sets: 3, reps: 10, weightKg: 60)])

    init() throws {
        f = try EngineFixture()
        let context = f.container.mainContext
        let clock = f.clock
        let service = ProposalService(context: context, exerciseExists: { _ in true }, now: { clock.now })
        engine = SyncEngine(store: f.store, transport: f.server, now: { clock.now },
                            autoApply: { try service.autoApplyPending() })
        try f.routines.upsert(push)
    }

    private var proposals: ProposalRepository {
        ProposalRepository(context: f.container.mainContext, now: { [clock = f.clock] in clock.now })
    }

    private func seedProposal() async -> UUID {
        let id = UUID()
        await f.server.seed(proposal: ProposalDTO(id: id, createdAt: f.clock.now.addingTimeInterval(-60),
                                                  summary: "Heavier bench", changes: [
            PlanChange(id: "c1", type: .weight, routineId: push.id.uuidString.lowercased(), exerciseId: "bench",
                       weightKg: 65),
            PlanChange(id: "c2", type: .sets, routineId: push.id.uuidString.lowercased(), exerciseId: "bench", sets: 4),
        ]))
        return id
    }

    @Test func pulledProposalAppearsPendingAndDismissPushesStatus() async throws {
        defer { f.tearDown() }
        let id = await seedProposal()
        await engine.sync()
        #expect(engine.status == .idle)
        #expect(try proposals.pending().map(\.id) == [id])
        #expect(try f.routines.routine(push.id)?.exercises.first?.weightKg == 60)

        try proposals.dismiss(id)
        await engine.sync()
        #expect(await f.server.proposals[id]?.status == "dismissed")
        #expect(try proposals.dirty().isEmpty)
        #expect(try proposals.proposal(id)?.status == .dismissed)
    }

    @Test func manualApplyPushesRoutinesAndAppliedIds() async throws {
        defer { f.tearDown() }
        let id = await seedProposal()
        await engine.sync()
        let service = ProposalService(context: f.container.mainContext, exerciseExists: { _ in true },
                                      now: { [clock = f.clock] in clock.now })
        try service.apply(id, changeIds: ["c1"])
        await engine.sync()
        let server = await f.server.proposals[id]
        #expect(server?.status == "partial" && server?.appliedChangeIds == ["c1"])
        #expect(await f.server.routines[push.id]?.exercises.first?.weightKg == 65)
    }

    @Test func autoApplyChangesRoutinesAndPushesAppliedStatusInTheSameRound() async throws {
        defer { f.tearDown() }
        try f.profiles.save(Profile(mcpAutoApply: true))
        let id = await seedProposal()
        await engine.sync()
        #expect(engine.status == .idle)
        let bench = try f.routines.routine(push.id)?.exercises.first
        #expect(bench?.weightKg == 65 && bench?.sets == 4 && bench?.weightSetAt == f.clock.now)
        #expect(try proposals.pending().isEmpty)
        #expect(await f.server.proposals[id]?.status == "applied")
        #expect(await f.server.proposals[id]?.appliedChangeIds == ["c1", "c2"])
        #expect(await f.server.routines[push.id]?.exercises.first?.weightKg == 65)
        #expect(engine.remoteChangeCount > 0)
    }

    @Test func autoApplyOffLeavesTheProposalPending() async throws {
        defer { f.tearDown() }
        let id = await seedProposal()
        await engine.sync()
        #expect(await f.server.proposals[id]?.status == "pending")
        #expect(try proposals.pending().count == 1)
    }

    @Test func proposalResolvedElsewhereDisappears() async throws {
        defer { f.tearDown() }
        let id = await seedProposal()
        await engine.sync()
        try await f.server.resolveProposal(id: id, status: "dismissed", appliedChangeIds: [], at: f.clock.now)
        await engine.sync()
        #expect(try proposals.pending().isEmpty)
    }

    // Item 8: one malformed proposal (unknown change type) must not break the round.
    @Test func malformedProposalIsSkippedAndRecordedWhileOthersSync() async throws {
        defer { f.tearDown() }
        let good = await seedProposal()
        let bad = UUID()
        await f.server.seed(malformedProposal: bad, createdAt: f.clock.now, changes: #"[{"id":"c1","type":"teleport"}]"#)
        await engine.sync()
        #expect(engine.status == .idle)
        #expect(try proposals.pending().map(\.id) == [good])
        let failure = try #require(f.store.syncFailures().first { $0.entity == .proposals })
        #expect(failure.id == bad.uuidString.lowercased())
        #expect(failure.message.contains("change"))
        await engine.sync() // still skipped, still recorded once
        #expect(f.store.syncFailures().filter { $0.entity == .proposals }.count == 1)
        await f.server.drop(malformedProposal: bad) // resolved or deleted elsewhere
        await engine.sync()
        #expect(f.store.syncFailures().filter { $0.entity == .proposals }.isEmpty)
    }

    @Test func refusedResolutionBecomesASyncFailureAndIsNotRetriedUntilEdited() async throws {
        defer { f.tearDown() }
        let id = await seedProposal()
        await engine.sync()
        try proposals.dismiss(id)
        await f.server.reject(ids: [id.uuidString])
        await engine.sync()
        #expect(await f.server.proposals[id]?.status == "pending")
        let failure = try #require(f.store.syncFailures().first { $0.entity == .proposals })
        #expect(failure.id == id.uuidString)
        let calls = await f.server.pushCalls
        await engine.sync()
        #expect(await f.server.pushCalls == calls) // blocked: the same edit isn't re-sent
        #expect(try proposals.dirty().count == 1)
    }

    @Test func revokeOAuthGrantsRevokesEveryGrant() async throws {
        defer { f.tearDown() }
        let claude = [UUID(), UUID()]
        await f.server.seed(grants: claude)
        #expect(try await engine.revokeOAuthGrants() == 2)
        #expect(await f.server.revokedGrants == claude)
        #expect(await f.server.grants.isEmpty)
        #expect(try await engine.revokeOAuthGrants() == 0)
    }
}
