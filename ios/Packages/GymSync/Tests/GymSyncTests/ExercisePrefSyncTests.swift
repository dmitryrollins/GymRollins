import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

@Suite struct ExercisePrefDTOTests {
    private let t0 = SyncDate.parse("2026-09-26T12:00:00.123456Z")!

    @Test func roundTripsAndEncodesSnakeCase() throws {
        let row = SyncRow(value: ExercisePreferenceSetting(exerciseId: "0025", preference: .never), clientUpdatedAt: t0)
        #expect(try wire(ExercisePrefDTO(row)).toDomain() == row)
        let json = try JSONSerialization.jsonObject(with: SyncJSON.encoder.encode(ExercisePrefDTO(row))) as? [String: Any]
        #expect(json?["exercise_id"] as? String == "0025")
        #expect(json?["pref"] as? String == "never")
        #expect(json?["client_updated_at"] as? String == "2026-09-26T12:00:00.123456Z")
        #expect(json?["updated_at"] == nil, "the server stamps updated_at")
        #expect(json?["user_id"] == nil, "the server fills user_id from auth.uid()")
    }

    @Test func unknownServerValuesDecodeAsNormal() throws {
        let body = #"[{"exercise_id":"0025","pref":"sometimes","client_updated_at":"2026-09-26T12:00:00Z","#
            + #""updated_at":"2026-09-26T12:00:01Z"}]"#
        let dto = try #require(try SyncJSON.decoder.decode([ExercisePrefDTO].self, from: Data(body.utf8)).first)
        #expect(dto.toDomain().value.preference == .normal)
        #expect(dto.updatedAt == SyncDate.parse("2026-09-26T12:00:01Z"))
    }
}

@MainActor
@Suite struct ExercisePrefEngineTests {
    let f: EngineFixture
    init() throws { f = try EngineFixture() }

    private var prefs: ExercisePreferenceRepository {
        ExercisePreferenceRepository(context: f.container.mainContext, now: { [clock = f.clock] in clock.now })
    }

    @Test func pushesDirtyPreferencesAndMarksThemSynced() async throws {
        defer { f.tearDown() }
        try prefs.set(.more, for: "0025")
        try prefs.set(.never, for: "custom-abc")
        await f.engine.sync()
        #expect(f.engine.status == .idle)
        #expect(await f.server.exercisePrefs["0025"]?.pref == "more")
        #expect(await f.server.exercisePrefs["custom-abc"]?.pref == "never")
        #expect(try f.store.dirtyExercisePreferences().isEmpty)
    }

    @Test func pullsAnotherDevicesPreference() async throws {
        defer { f.tearDown() }
        let other = SyncRow(value: ExercisePreferenceSetting(exerciseId: "0070", preference: .less),
                            clientUpdatedAt: f.clock.now)
        try await f.server.seed(exercisePref: ExercisePrefDTO(other))
        await f.engine.sync()
        #expect(try prefs.preference(for: "0070") == .less)
        #expect(f.engine.remoteChangeCount > 0)
    }

    @Test func olderLocalEditLosesToTheServer() async throws {
        defer { f.tearDown() }
        try prefs.set(.more, for: "0025") // edited offline at t
        f.clock.advance()
        let newer = SyncRow(value: ExercisePreferenceSetting(exerciseId: "0025", preference: .never),
                            clientUpdatedAt: f.clock.now)
        try await f.server.seed(exercisePref: ExercisePrefDTO(newer))
        await f.engine.sync()
        #expect(await f.server.exercisePrefs["0025"]?.pref == "never", "the server kept the newer edit")
        #expect(try prefs.preference(for: "0025") == .never, "the pull replaced the older local edit")
        #expect(try f.store.dirtyExercisePreferences().isEmpty)
    }

    @Test func aRejectedPreferenceIsRecordedAndDoesNotBlockTheRest() async throws {
        defer { f.tearDown() }
        try prefs.set(.more, for: "0025")
        try prefs.set(.less, for: "0070")
        await f.server.reject(ids: ["0070"])
        await f.engine.sync()
        #expect(await f.server.exercisePrefs["0025"]?.pref == "more")
        #expect(f.store.syncFailures().map(\.id) == ["0070"])
        #expect(f.store.syncFailures().first?.entity == .exercisePreferences)
    }
}
