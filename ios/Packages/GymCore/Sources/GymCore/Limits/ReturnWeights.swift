import Foundation

/// Coming back after an injury break: a paused routine restarts at 60% of what would have been planned, so the first
/// session is light and progression builds up again from what's logged.
public enum ReturnWeights {
    public static let fraction = 0.6

    /// 60% of `suggestedKg`, rounded down on `rounder` with its pound number (in lb the grid value is one, plan 38),
    /// and never below `minimum` (the empty bar, or the smallest step), which is returned as given. Nil when there's
    /// no weight to lower.
    public static func weight(from suggestedKg: Double, rounder: LoadRounder, minimum: PoundWeight) -> PoundWeight? {
        guard suggestedKg > 0 else { return nil }
        let light = rounder.downWeight(suggestedKg * fraction)
        return light.kg < minimum.kg ? minimum : light
    }

    /// `routine` unpaused, with each weighted rep exercise planned at `newWeight(item)` from `now`, kg and pound number
    /// together. The engine prefers a weight planned after the last session, so the first session back uses it. Timed
    /// and cardio exercises, those whose progression is Off (the person sets those weights), those with a fixed weight
    /// (the engine returns it before any planned weight), and those `newWeight` returns nil for keep their weight.
    public static func resume(_ routine: Routine, now: Date,
                              newWeight: (RoutineExercise) -> PoundWeight?) -> (routine: Routine, lowered: Int) {
        let changes = routine.exercises.map { item -> RoutineExercise? in
            guard item.mode == .reps, item.fixedWeightKg == nil, (item.policy ?? routine.policy) != .off,
                  let weight = newWeight(item) else { return nil }
            return item.with(weight: weight, setAt: now)
        }
        let items = zip(routine.exercises, changes).map { original, changed in changed ?? original }
        let resumed = Routine(id: routine.id, name: routine.name, emoji: routine.emoji, policy: routine.policy,
                              paused: false, exercises: items)
        return (resumed, changes.compactMap { $0 }.count)
    }
}
