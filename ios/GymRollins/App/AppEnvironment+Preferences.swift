import Foundation
import GymCore
import GymData

// Exercise recommendation preferences ("Recommend more often / less often / Don't recommend again").
extension AppEnvironment {
    func preference(for exerciseId: String) -> ExercisePreference {
        exercisePreferences[exerciseId] ?? .normal
    }

    /// Stores the choice, refreshes what screens show and schedules a sync.
    func setPreference(_ preference: ExercisePreference, for exerciseId: String) throws {
        try exercisePrefs.set(preference, for: exerciseId)
        reloadExercisePreferences()
        sync.localDataChanged()
    }

    /// "Don't recommend again" exercises for Settings → Hidden Exercises, by display name.
    func hiddenExercises() -> [(id: String, name: String)] {
        exercisePreferences.filter { $0.value == .never }.keys
            .map { (id: $0, name: library.exercise($0).map { DisplayName.of($0.name) } ?? $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func reloadExercisePreferences() {
        do { exercisePreferences = try exercisePrefs.all() }
        catch { Self.log.error("Reload exercise preferences failed: \(error.localizedDescription, privacy: .public)") }
    }
}
