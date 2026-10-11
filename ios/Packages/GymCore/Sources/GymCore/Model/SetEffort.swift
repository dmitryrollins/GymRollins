import Foundation

/// "How hard was that set": reps left in the tank (RIR), rated with one optional tap after the last working set of an exercise is logged.
/// The chips are 0 (failure) … 4 ("4+", stored as 4). Stored on `WorkoutSet.rir`; read by `HardSets` (recovery) and
/// `ProgressionEngine` (early increase / hold).
public enum SetEffort {
    public static let choices = [0, 1, 2, 3, 4]

    /// Done working sets of a reps-mode exercise; never warm-ups, timed or cardio sets.
    public static func canRate(_ set: WorkoutSet, mode: ExerciseMode) -> Bool {
        mode == .reps && set.done && !set.warmup
    }

    /// The chip shown selected for a stored RIR: anything from 4 up is "4+", a fraction shows the harder chip.
    public static func choice(for rir: Double?) -> Int? {
        guard let rir else { return nil }
        return clamp(Int(rir.rounded(.down)))
    }

    /// The RIR after tapping `choice`: the selected chip clears it, any other chip replaces it.
    public static func toggled(_ current: Double?, tapping choice: Int) -> Double? {
        let tapped = clamp(choice)
        return Self.choice(for: current) == tapped ? nil : Double(tapped)
    }

    /// The set that gets the "Reps left?" row: asked once per exercise, after its last working set is logged, on
    /// that set (the last one in order). Nil while a working set is still to do.
    public static func promptSetId(in sets: [WorkoutSet], mode: ExerciseMode) -> UUID? {
        let working = sets.filter { !$0.warmup }
        guard mode == .reps, let last = working.last, working.allSatisfy(\.done) else { return nil }
        return last.id
    }

    private static func clamp(_ choice: Int) -> Int { min(max(choice, choices[0]), choices[choices.count - 1]) }
}
