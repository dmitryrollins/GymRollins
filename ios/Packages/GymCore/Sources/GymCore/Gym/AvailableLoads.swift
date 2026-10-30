import Foundation

/// A suggested weight and rep target after fitting them to what a listing offers.
public struct FittedLoad: Sendable, Equatable {
    public let weightKg: Double
    public let reps: Int
    /// The suggestion was heavier than anything available: the heaviest weight is kept and the rep target raised.
    public let atHeaviest: Bool

    public init(weightKg: Double, reps: Int, atHeaviest: Bool = false) {
        self.weightKg = weightKg
        self.reps = reps
        self.atHeaviest = atHeaviest
    }
}

/// Fits a progression suggestion to a listing's loads (spec §5, Build workout step 8): a weight stack caps and
/// snaps to its step, a fixed set picks the nearest weight it has (ties go to the lighter one). Past the heaviest
/// weight the load stays there and the rep target goes up instead. Plates and no-load listings change nothing; the
/// existing plate rounding already applies to them.
public enum AvailableLoads {
    /// Reps added to the target when the suggestion is past the heaviest available weight.
    public static let extraRepsAtHeaviest = 2
    /// Float noise from kg <-> lb conversion: this close to the heaviest weight isn't past it.
    private static let toleranceKg = 0.01

    public static func fit(weightKg: Double, reps: Int, to loads: ListingLoads) -> FittedLoad {
        let unchanged = FittedLoad(weightKg: weightKg, reps: reps)
        guard weightKg > 0 else { return unchanged }
        switch loads {
        case let .stack(maxKg, stepKg):
            guard maxKg > 0 else { return unchanged }
            if weightKg > maxKg + toleranceKg { return heaviest(maxKg, reps: reps) }
            guard let stepKg, stepKg > 0 else { return FittedLoad(weightKg: min(weightKg, maxKg), reps: reps) }
            let snapped = min(maxKg, max(stepKg, (weightKg / stepKg).rounded() * stepKg))
            return FittedLoad(weightKg: snapped, reps: reps)
        case let .fixed(kg):
            let weights = kg.filter { $0 > 0 }.sorted()
            guard let top = weights.last else { return unchanged }
            if weightKg > top + toleranceKg { return heaviest(top, reps: reps) }
            let nearest = weights.min { abs($0 - weightKg) < abs($1 - weightKg) } ?? top
            return FittedLoad(weightKg: nearest, reps: reps)
        case .plates, .none:
            return unchanged
        }
    }

    private static func heaviest(_ kg: Double, reps: Int) -> FittedLoad {
        FittedLoad(weightKg: kg, reps: reps + extraRepsAtHeaviest, atHeaviest: true)
    }
}
