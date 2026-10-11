import Foundation

/// Which logged sets count as "hard sets" for recovery and weekly targets, and how hard they were.
public enum HardSets {
    /// Done, not a warm-up, and with some work in it (reps, or time for timed sets). Weight may be 0 (bodyweight).
    public static func isHard(_ set: WorkoutSet) -> Bool {
        guard set.done, !set.warmup else { return false }
        return set.reps > 0 || (set.sec ?? 0) > 0 || (set.minutes ?? 0) > 0
    }

    /// Effort multiplier from reps in reserve (logged RIR, else 10 − RPE); 1 when neither was logged.
    /// RIR 0–1 → 1.0, 2 → 0.9, 3 → 0.75, 4 → 0.6, 5+ → 0.5 (fractions round down to the harder band).
    public static func effort(_ set: WorkoutSet) -> Double {
        guard let rir = set.rir ?? set.rpe.map({ 10 - $0 }) else { return 1 }
        switch rir.rounded(.down) {
        case ..<2: return 1
        case 2: return 0.9
        case 3: return 0.75
        case 4: return 0.6
        default: return 0.5
        }
    }
}

/// Per-group work in one workout: `sets` = hard sets weighted by role (primary 1, secondary 0.5) for weekly
/// counts; `load` = the same with each set's effort applied, for recovery.
public enum MuscleLoads {
    public struct Load: Equatable, Sendable {
        public var sets: Double
        public var load: Double

        public init(sets: Double, load: Double) {
            self.sets = sets
            self.load = load
        }
    }

    public static func of(_ workout: Workout, exercise: (String) -> Exercise?) -> [MuscleGroup: Load] {
        var out: [MuscleGroup: Load] = [:]
        for entry in workout.entries {
            guard let ex = exercise(entry.exerciseId) else { continue }
            let contributions = MuscleTaxonomy.contributions(for: ex)
            guard !contributions.isEmpty else { continue }
            let hard = entry.sets.filter(HardSets.isHard)
            guard !hard.isEmpty else { continue }
            let count = Double(hard.count)
            let effort = hard.reduce(0) { $0 + HardSets.effort($1) }
            for c in contributions {
                let current = out[c.group] ?? Load(sets: 0, load: 0)
                out[c.group] = Load(sets: current.sets + count * c.weight, load: current.load + effort * c.weight)
            }
        }
        return out
    }
}
