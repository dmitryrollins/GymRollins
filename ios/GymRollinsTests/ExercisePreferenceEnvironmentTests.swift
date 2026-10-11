import Foundation
import GymCore
import Testing
@testable import GymRollins

@MainActor
@Suite struct ExercisePreferenceEnvironmentTests {
    private func env() throws -> AppEnvironment {
        let defaults = try #require(UserDefaults(suiteName: "ExercisePreferenceEnvironmentTests.\(UUID())"))
        return try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]), defaults: defaults)
    }

    @Test func settingAPreferenceUpdatesTheEnvironmentAndIsStored() throws {
        let env = try env()
        #expect(env.preference(for: "0025") == .normal)
        try env.setPreference(.more, for: "0025")
        try env.setPreference(.never, for: "0070")
        #expect(env.preference(for: "0025") == .more)
        #expect(env.exercisePreferences == ["0025": .more, "0070": .never])
        #expect(try env.exercisePrefs.all() == ["0025": .more, "0070": .never])
        #expect(try env.syncStore.dirtyExercisePreferences().count == 2, "queued for sync")
    }

    @Test func hiddenExercisesAreTheNeverOnesByName() throws {
        let env = try env()
        try env.setPreference(.never, for: "0025")
        try env.setPreference(.less, for: "0070")
        #expect(env.hiddenExercises().map(\.id) == ["0025"])
        #expect(env.hiddenExercises().first?.name == "Barbell Bench Press")
        try env.setPreference(.normal, for: "0025")
        #expect(env.hiddenExercises().isEmpty)
    }

    @Test func erasingLocalDataClearsPreferences() throws {
        let env = try env()
        try env.setPreference(.never, for: "0025")
        try env.eraseAllLocalData()
        #expect(env.exercisePreferences.isEmpty)
    }
}
