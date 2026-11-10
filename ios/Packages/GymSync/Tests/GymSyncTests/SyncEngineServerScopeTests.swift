import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// A server that keeps neither gyms nor proposals (the API until plans 28 and 29): the round leaves them out and syncs
/// the rest. A busy or rate-limited server reads as offline.
@MainActor
@Suite struct SyncEngineServerScopeTests {
    let f: EngineFixture
    init() throws { f = try EngineFixture() }

    @Test func gymsAndProposalsWaitForAServerThatKeepsThem() async throws {
        defer { f.tearDown() }
        let server = FakeTransport(servesGyms: false, servesProposals: false)
        let engine = SyncEngine(store: f.store, transport: server, now: { [clock = f.clock] in clock.now })
        let gyms = GymRepository(context: f.container.mainContext, now: { [clock = f.clock] in clock.now })
        let gym = try gyms.addPrivateGym(name: "Home", address: nil)
        try gyms.makeSynced(gym: gym.id)
        await server.seed(proposal: ProposalDTO(id: UUID(), createdAt: f.clock.now, summary: "Heavier bench", changes: [
            PlanChange(id: "c1", type: .weight, routineId: UUID().uuidString.lowercased(), exerciseId: "bench",
                       weightKg: 65),
        ]))
        let workout = Workout(startedAt: f.clock.now, endedAt: f.clock.now.addingTimeInterval(600), name: "Push")
        try f.workouts.save(workout)

        await engine.sync()

        #expect(engine.status == .idle)
        #expect(await server.callLog == ["push:workout", "pull:workouts"])
        #expect(await server.workouts[workout.id] != nil)
        #expect(try f.store.dirtyGyms().map(\.value.id) == [gym.id], "the gym waits, still unsynced")
        #expect(try f.store.pendingProposalIds().isEmpty, "no proposal was pulled")
    }

    @Test func aDirtyResolutionIsNotSentToAServerWithoutProposals() async throws {
        defer { f.tearDown() }
        let server = FakeTransport(servesGyms: false, servesProposals: false)
        let engine = SyncEngine(store: f.store, transport: server, now: { [clock = f.clock] in clock.now })
        let id = UUID()
        let change = PlanChange(id: "c1", type: .weight, routineId: UUID().uuidString.lowercased(), exerciseId: "bench",
                                weightKg: 65)
        await server.seed(proposal: ProposalDTO(id: id, createdAt: f.clock.now, summary: "Heavier bench",
                                                changes: [change]))
        try f.store.applyRemote(proposals: [Proposal(id: id, createdAt: f.clock.now, summary: "Heavier bench",
                                                     changes: [change])])
        try ProposalRepository(context: f.container.mainContext, now: { [clock = f.clock] in clock.now }).dismiss(id)
        #expect(try f.store.dirtyProposals().count == 1)

        await engine.sync()

        #expect(engine.status == .idle, "the round finishes")
        #expect(await server.callLog == ["pull:workouts"], "no proposal call went out")
        #expect(await server.proposals[id]?.status == "pending", "the server never heard of the resolution")
        #expect(try f.store.dirtyProposals().count == 1, "it stays unsent for a server that keeps proposals")
    }

    @Test func aBusyOrRateLimitedServerReadsAsOffline() {
        #expect(SyncEngine.status(for: ApiError(status: 503, code: "http_503", message: "")) == .offline)
        #expect(SyncEngine.status(for: ApiError(status: 429, code: "rate_limited", message: "")) == .offline)
        #expect(SyncEngine.status(for: URLError(.notConnectedToInternet)) == .offline)
        #expect(SyncEngine.status(for: ApiError(status: 400, code: "bad_request", message: ""))
            == .error("Couldn't sync. Your data is safe on this iPhone; we'll try again later."))
    }
}
