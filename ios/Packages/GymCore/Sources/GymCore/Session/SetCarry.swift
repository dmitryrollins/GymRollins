import Foundation

/// Changing a working set's value (weight, reps, seconds, ...) carries it to the later sets still to do, the way the
/// owner expects from a gym log: those holding the same value as the edited set follow; the first one holding another
/// (set by hand) stops the carry, and logged sets and warm-ups (which have their own ramp) are skipped. Editing a
/// logged set corrects history and carries nothing; neither does editing a warm-up.
public enum SetCarry {
    /// Ids of the sets after `edited` that take its new value: the later working sets still to do whose `value` equals
    /// the edited set's, up to the first that differs. `sets` are as they were before the edit.
    public static func following<V: Equatable>(_ sets: [WorkoutSet], edited: UUID,
                                               value: (WorkoutSet) -> V) -> [UUID] {
        guard let index = sets.firstIndex(where: { $0.id == edited }), !sets[index].warmup, !sets[index].done
        else { return [] }
        let old = value(sets[index])
        var out: [UUID] = []
        for set in sets[(index + 1)...] where !set.done && !set.warmup {
            guard value(set) == old else { break }
            out.append(set.id)
        }
        return out
    }
}
