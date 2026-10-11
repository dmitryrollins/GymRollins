public enum WorkoutMetrics {
    public static func workingSets(_ entry: WorkoutEntry) -> [WorkoutSet] {
        entry.sets.filter { $0.done && !$0.warmup }
    }

    public static func volumeKg(_ entry: WorkoutEntry) -> Double {
        workingSets(entry).reduce(0) { $0 + $1.weightKg * Double($1.reps) * $1.multiplier }
    }

    public static func volumeKg(_ workout: Workout) -> Double {
        workout.entries.reduce(0) { $0 + volumeKg($1) }
    }

    public static func workingSetCount(_ workout: Workout) -> Int {
        workout.entries.reduce(0) { $0 + workingSets($1).count }
    }

    public static func bestE1RM(_ entry: WorkoutEntry, formula: OneRepMaxFormula = .epley) -> Double? {
        workingSets(entry).compactMap { OneRepMax.estimate(weightKg: $0.weightKg, reps: $0.reps, formula: formula) }.max()
    }

    /// The working set with the highest estimated 1RM (the "best set"), across all working sets.
    public static func bestE1RMSet(_ entry: WorkoutEntry, formula: OneRepMaxFormula = .epley) -> WorkoutSet? {
        workingSets(entry)
            .compactMap { set in OneRepMax.estimate(weightKg: set.weightKg, reps: set.reps, formula: formula).map { (set, $0) } }
            .max { $0.1 < $1.1 }?.0
    }
}
