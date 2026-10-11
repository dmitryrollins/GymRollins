import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

@MainActor
@Suite struct SyncEngineTargetsTests {
    let f: EngineFixture
    init() throws { f = try EngineFixture() }

    var targets: MuscleTargetRepository {
        MuscleTargetRepository(context: f.container.mainContext, now: { [clock = f.clock] in clock.now })
    }

    @Test func dtoRoundTripsOverTheWire() throws {
        let row = SyncRow(value: MuscleTargetValue(group: .upperBack, range: SetTargetRange(min: 12, max: 18)),
                          clientUpdatedAt: f.clock.now)
        let json = String(decoding: try SyncJSON.encoder.encode(MuscleTargetDTO(row)), as: UTF8.self)
        #expect(json.contains(#""muscle":"upper_back""#))
        #expect(json.contains(#""min_sets":12"#))
        #expect(json.contains(#""max_sets":18"#))
        #expect(!json.contains("updated_at\":null")) // server-owned, never sent
        let back = try SyncJSON.decoder.decode(MuscleTargetDTO.self, from: Data(json.utf8)).toDomain()
        #expect(back?.value == row.value)
        let unknown = #"{"muscle":"neck","min_sets":1,"max_sets":2,"client_updated_at":"2026-09-26T12:00:00.000000Z"}"#
        #expect(try SyncJSON.decoder.decode(MuscleTargetDTO.self, from: Data(unknown.utf8)).toDomain() == nil)
    }

    @Test func pushesDirtyTargetsAndMarksThemSynced() async throws {
        defer { f.tearDown() }
        try targets.set(.chest, SetTargetRange(min: 12, max: 18))
        await f.engine.sync()
        #expect(f.engine.status == .idle)
        #expect(await f.server.muscleTargets["chest"]?.minSets == 12)
        #expect(try f.store.dirtyMuscleTargets().isEmpty)
    }

    @Test func pullsTargetsSetOnAnotherDevice() async throws {
        defer { f.tearDown() }
        try await f.server.seed(muscleTarget: MuscleTargetDTO(SyncRow(
            value: MuscleTargetValue(group: .lats, range: SetTargetRange(min: 14, max: 22)), clientUpdatedAt: f.clock.now)))
        await f.engine.sync()
        #expect(try targets.all()[.lats] == SetTargetRange(min: 14, max: 22))
        #expect(f.store.cursor(for: .muscleTargets) != nil)
    }

    @Test func olderLocalEditLosesToTheServer() async throws {
        defer { f.tearDown() }
        try targets.set(.chest, SetTargetRange(min: 12, max: 18))
        try await f.server.seed(muscleTarget: MuscleTargetDTO(SyncRow(
            value: MuscleTargetValue(group: .chest, range: SetTargetRange(min: 5, max: 9)),
            clientUpdatedAt: f.clock.now.addingTimeInterval(60))))
        await f.engine.sync()
        #expect(try targets.all()[.chest] == SetTargetRange(min: 5, max: 9))
        #expect(try f.store.dirtyMuscleTargets().isEmpty)
    }
}
