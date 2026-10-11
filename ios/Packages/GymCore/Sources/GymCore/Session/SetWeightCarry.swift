import Foundation

/// Changing a working set's weight carries it to the later sets still to do, the way the owner expects from a
/// gym log: those still at the old weight follow; a set already changed by hand stops the carry, and logged sets
/// and warm-ups (which have their own ramp) are skipped.
public enum SetWeightCarry {
    /// Ids of the sets after `edited` that should take its new weight, given its weight before the edit.
    public static func following(_ sets: [WorkoutSet], edited: UUID, fromKg: Double) -> [UUID] {
        guard let index = sets.firstIndex(where: { $0.id == edited }), !sets[index].warmup else { return [] }
        var out: [UUID] = []
        for set in sets[(index + 1)...] where !set.done && !set.warmup {
            guard abs(set.weightKg - fromKg) < 0.001 else { break }
            out.append(set.id)
        }
        return out
    }
}
