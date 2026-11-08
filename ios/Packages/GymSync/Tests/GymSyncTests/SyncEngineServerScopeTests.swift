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

    @Test func aBusyOrRateLimitedServerReadsAsOffline() {
        #expect(SyncEngine.status(for: ApiError(status: 503, code: "http_503", message: "")) == .offline)
        #expect(SyncEngine.status(for: ApiError(status: 429, code: "rate_limited", message: "")) == .offline)
        #expect(SyncEngine.status(for: URLError(.notConnectedToInternet)) == .offline)
        #expect(SyncEngine.status(for: ApiError(status: 400, code: "bad_request", message: ""))
            == .error("Couldn't sync. Your data is safe on this iPhone; we'll try again later."))
    }
}
