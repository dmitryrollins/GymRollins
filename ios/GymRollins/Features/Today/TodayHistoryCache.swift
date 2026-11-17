import GymCore
import GymData

/// Recent sessions per exercise, shared by Today's rows and the plan-mode exercise screen's suggestions. Each exercise
/// is read once, until `invalidate()` (the workout data changed): a new plan, gym or day only needs its new exercises
/// read. Not observed, so filling it while a view body reads it never invalidates a view mid-update.
@MainActor
final class TodayHistoryCache {
    /// Sessions read per exercise (what progression and the planned targets look at).
    static let limit = 5

    private var byExercise: [String: [SessionResult]] = [:]

    /// The exercise's recent sessions from the store.
    func sessions(_ exerciseId: String, in workouts: WorkoutRepository) -> [SessionResult] {
        sessions(exerciseId) { try workouts.history(exerciseId: $0, limit: Self.limit) }
    }

    /// The exercise's sessions, read with `load` the first time they're asked for. A failed read shows none (logged)
    /// and is tried again next time.
    func sessions(_ exerciseId: String, load: (String) throws -> [SessionResult]) -> [SessionResult] {
        if let cached = byExercise[exerciseId] { return cached }
        do {
            let loaded = try load(exerciseId)
            byExercise[exerciseId] = loaded
            return loaded
        } catch {
            AppEnvironment.log.error("Today history read failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Forget every exercise's sessions (a workout was finished, edited, deleted or synced).
    func invalidate() { byExercise = [:] }
}
