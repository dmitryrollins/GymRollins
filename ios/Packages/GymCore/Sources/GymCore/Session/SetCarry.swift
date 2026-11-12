import Foundation

/// Changing a working set's weight, reps or seconds carries it to the later sets still to do, the way the owner
/// expects from a gym log: those still at the old value follow; a set already changed by hand stops the carry for
/// that value, and logged sets and warm-ups (which have their own ramp) are skipped. Each value carries on its own.
public enum SetCarry {
    /// Ids of the sets after `edited` that should take its new weight, given its weight before the edit.
    public static func following(_ sets: [WorkoutSet], edited: UUID, fromKg: Double) -> [UUID] {
        following(sets, edited: edited) { abs($0.weightKg - fromKg) < 0.001 }
    }

    /// Ids of the sets after `edited` that should take its new reps, given its reps before the edit.
    public static func following(_ sets: [WorkoutSet], edited: UUID, fromReps: Int) -> [UUID] {
        following(sets, edited: edited) { $0.reps == fromReps }
    }

    /// Ids of the sets after `edited` that should take its new duration, given its seconds before the edit.
    public static func following(_ sets: [WorkoutSet], edited: UUID, fromSec: Int?) -> [UUID] {
        following(sets, edited: edited) { $0.sec == fromSec }
    }

    private static func following(_ sets: [WorkoutSet], edited: UUID, holdsOldValue: (WorkoutSet) -> Bool) -> [UUID] {
        guard let index = sets.firstIndex(where: { $0.id == edited }), !sets[index].warmup else { return [] }
        var out: [UUID] = []
        for set in sets[(index + 1)...] where !set.done && !set.warmup {
            guard holdsOldValue(set) else { break }
            out.append(set.id)
        }
        return out
    }
}
