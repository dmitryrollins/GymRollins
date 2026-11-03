import Foundation

/// Coming back after an injury break: a paused routine restarts at 60% of what would have been planned, so the first
/// session is light and progression builds up again from what's logged.
public enum ReturnWeights {
    public static let fraction = 0.6

    /// 60% of `suggestedKg`, rounded down on `rounder`, and never below `minimumKg` (the empty bar, or the smallest
    /// step). Nil when there's no weight to lower.
    public static func weight(from suggestedKg: Double, rounder: LoadRounder, minimumKg: Double) -> Double? {
        guard suggestedKg > 0 else { return nil }
        return max(rounder.down(suggestedKg * fraction), minimumKg)
    }

    /// `routine` unpaused, with each weighted rep exercise planned at `newWeight(item)` from `now`. The engine prefers a
    /// weight planned after the last session, so the first session back uses it. Timed and cardio exercises, those whose
    /// progression is Off (the person sets those weights), and those `newWeight` returns nil for keep their weight.
    public static func resume(_ routine: Routine, now: Date,
                              newWeight: (RoutineExercise) -> Double?) -> (routine: Routine, lowered: Int) {
        let changes = routine.exercises.map { item -> RoutineExercise? in
            guard item.mode == .reps, (item.policy ?? routine.policy) != .off, let kg = newWeight(item) else { return nil }
            return item.with(weightKg: kg, setAt: now)
        }
        let items = zip(routine.exercises, changes).map { original, changed in changed ?? original }
        let resumed = Routine(id: routine.id, name: routine.name, emoji: routine.emoji, policy: routine.policy,
                              paused: false, exercises: items)
        return (resumed, changes.compactMap { $0 }.count)
    }
}
