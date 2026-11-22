import Foundation

/// The weights a gym's dumbbells or kettlebells were seen with in workouts (owner, 2026-11-22): a list that grows as
/// workouts show more, never the gym's whole rack.
public enum LearnedWeights {
    /// The weights (kg) that can be stored for a fixed set, sorted; those within `AvailableLoads.toleranceKg` of each
    /// other count once (the lighter one is kept).
    public static func distinct(_ kg: [Double]) -> [Double] {
        var kept: [Double] = []
        for weight in kg.filter(DomainLimits.listingFixedKg.contains).sorted() {
            if let last = kept.last, weight - last <= AvailableLoads.toleranceKg { continue }
            kept.append(weight)
        }
        return kept
    }

    /// `existing` with the new weights added: what is there stays, and the list stops at the most a listing can hold.
    public static func merged(_ existing: [Double], with new: [Double]) -> [Double] {
        var weights = existing
        for weight in distinct(new) where weights.count < DomainLimits.listingFixedWeightsMax {
            if !weights.contains(where: { abs($0 - weight) <= AvailableLoads.toleranceKg }) { weights.append(weight) }
        }
        return weights.sorted()
    }
}
