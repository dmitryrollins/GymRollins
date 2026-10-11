import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

@MainActor
@Suite struct ExercisePreferenceRepositoryTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    private var prefs: ExercisePreferenceRepository {
        ExercisePreferenceRepository(context: f.context, now: { [clock = f.clock] in clock.now })
    }

    @Test func defaultsToNormalAndStoresChoices() throws {
        defer { f.tearDown() }
        #expect(try prefs.preference(for: "0025") == .normal)
        try prefs.set(.more, for: "0025")
        try prefs.set(.never, for: "0070")
        #expect(try prefs.preference(for: "0025") == .more)
        #expect(try prefs.all() == ["0025": .more, "0070": .never])
        #expect(try prefs.hidden() == ["0070"])
    }

    @Test func settingNormalKeepsARowSoTheResetSyncs() throws {
        defer { f.tearDown() }
        try prefs.set(.never, for: "0070")
        f.clock.advance()
        try prefs.set(.normal, for: "0070")
        #expect(try prefs.all().isEmpty)
        #expect(try prefs.hidden().isEmpty)
        let dirty = try f.store.dirtyExercisePreferences()
        #expect(dirty.map(\.value) == [ExercisePreferenceSetting(exerciseId: "0070", preference: .normal)])
        #expect(dirty.first?.clientUpdatedAt == f.clock.now)
    }

    @Test func settingTheSameValueDoesNotDirtyTheRow() throws {
        defer { f.tearDown() }
        try prefs.set(.less, for: "0025")
        let row = try #require(try f.store.dirtyExercisePreferences().first)
        try f.store.markSynced(.exercisePreferences, id: "0025", clientUpdatedAt: row.clientUpdatedAt,
                               serverUpdatedAt: f.clock.now)
        f.clock.advance()
        try prefs.set(.less, for: "0025")
        #expect(try f.store.dirtyExercisePreferences().isEmpty)
    }

    @Test func rejectsInvalidExerciseIds() throws {
        defer { f.tearDown() }
        #expect(throws: GymDataError.self) { try prefs.set(.more, for: "") }
        #expect(throws: GymDataError.self) { try prefs.set(.more, for: String(repeating: "x", count: 81)) }
        #expect(throws: GymDataError.self) { try prefs.set(.more, for: "bad id;") }
    }
}

@MainActor
@Suite struct ExercisePreferenceSyncTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    private var prefs: ExercisePreferenceRepository {
        ExercisePreferenceRepository(context: f.context, now: { [clock = f.clock] in clock.now })
    }

    private func row(_ id: String, _ pref: ExercisePreference, at date: Date) -> SyncRow<ExercisePreferenceSetting> {
        SyncRow(value: ExercisePreferenceSetting(exerciseId: id, preference: pref), clientUpdatedAt: date,
                serverUpdatedAt: date.addingTimeInterval(1))
    }

    @Test func markSyncedClearsDirtyOnlyForThePushedEdit() throws {
        defer { f.tearDown() }
        try prefs.set(.more, for: "0025")
        let pushed = try #require(try f.store.dirtyExercisePreferences().first)
        f.clock.advance()
        try prefs.set(.less, for: "0025") // edited while the push was in flight
        try f.store.markSynced(.exercisePreferences, id: "0025", clientUpdatedAt: pushed.clientUpdatedAt,
                               serverUpdatedAt: f.clock.now)
        #expect(try f.store.dirtyExercisePreferences().map(\.value.preference) == [.less])
    }

    @Test func remoteRowsAreStoredClean() throws {
        defer { f.tearDown() }
        try f.store.applyRemote(exercisePreferences: [row("0025", .never, at: f.clock.now)])
        #expect(try prefs.preference(for: "0025") == .never)
        #expect(try f.store.dirtyExercisePreferences().isEmpty)
    }

    @Test func lastWriteWinsAgainstADirtyLocalEdit() throws {
        defer { f.tearDown() }
        let older = f.clock.now
        f.clock.advance()
        try prefs.set(.more, for: "0025")
        try f.store.applyRemote(exercisePreferences: [row("0025", .never, at: older)])
        #expect(try prefs.preference(for: "0025") == .more, "the newer local edit stays")
        f.clock.advance()
        try f.store.applyRemote(exercisePreferences: [row("0025", .less, at: f.clock.now)])
        #expect(try prefs.preference(for: "0025") == .less, "a newer remote edit wins")
        #expect(try f.store.dirtyExercisePreferences().isEmpty)
    }

    @Test func unknownRemoteValuesReadAsNormal() throws {
        defer { f.tearDown() }
        try prefs.set(.more, for: "0025")
        f.clock.advance()
        try f.store.applyRemote(exercisePreferences: [row("0025", .normal, at: f.clock.now)])
        #expect(try prefs.all().isEmpty)
    }

    @Test func resetAllWipesPreferences() throws {
        defer { f.tearDown() }
        try prefs.set(.never, for: "0025")
        #expect(try f.store.hasLocalData())
        try f.store.resetAll()
        #expect(try prefs.all().isEmpty)
        #expect(try f.store.dirtyExercisePreferences().isEmpty)
    }
}
