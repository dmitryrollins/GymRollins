import Foundation

/// One exercise's hard sets in one workout that worked a muscle group.
public struct MuscleSession: Equatable, Sendable, Identifiable {
    public var id: String { "\(workoutId.uuidString)-\(entryId.uuidString)" }
    public let workoutId: UUID
    public let entryId: UUID
    public let date: Date
    public let exerciseId: String
    public let sets: [WorkoutSet]
    public let isPrimary: Bool
}

public enum MuscleHistory {
    /// The most recent entries (newest workout first, entry order within a workout) with hard sets for `group`.
    public static func recent(group: MuscleGroup, workouts: [Workout], exercise: (String) -> Exercise?,
                              limit: Int = 6) -> [MuscleSession] {
        var out: [MuscleSession] = []
        for workout in workouts.sorted(by: { $0.startedAt > $1.startedAt }) {
            for entry in workout.entries {
                guard let ex = exercise(entry.exerciseId),
                      let role = MuscleTaxonomy.contributions(for: ex).first(where: { $0.group == group }) else { continue }
                let hard = entry.sets.filter(HardSets.isHard)
                guard !hard.isEmpty else { continue }
                out.append(MuscleSession(workoutId: workout.id, entryId: entry.id, date: workout.startedAt,
                                         exerciseId: entry.exerciseId, sets: hard, isPrimary: role.isPrimary))
                if out.count >= limit { return out }
            }
        }
        return out
    }
}

/// Muscle groups the owner's free-text limits note puts off-limits. There is no structured injury model: this only
/// recognises a knee or leg mention ("Knee: no leg loading until ~26 Oct 2026") and flags the leg groups, for
/// display on the map and to keep them out of the "Fresh" hint. It changes no recovery maths or plan logic.
public enum LimitedMuscles {
    public static func from(limits: String) -> Set<MuscleGroup> {
        let words = limits.lowercased().split { !$0.isLetter }.map(String.init)
        return words.contains { ["knee", "knees", "leg", "legs"].contains($0) } ? MuscleGroup.legs : []
    }
}
