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
    /// This close to the heaviest weight isn't past it: about half a display unit in either unit, so a 53 lb bell
    /// (24.04 kg) is the 24 kg bell and not a weight that rose.
    public static let toleranceKg = 0.25

    /// A fit raises the weight by at most this much, or by `maxRiseFraction` of it when that is more. The loads of a
    /// shared gym may be someone's typo (a 500 kg bell, a stack that moves in 50 kg steps), and a jump of that size is
    /// not a progression. Going down has no limit.
    public static let maxRiseKg = 5.0
    public static let maxRiseFraction = 0.25

    public static func fit(weightKg: Double, reps: Int, to loads: ListingLoads) -> FittedLoad {
        let unchanged = FittedLoad(weightKg: weightKg, reps: reps)
        guard weightKg > 0 else { return unchanged }
        let allowedRise = max(maxRiseKg, weightKg * maxRiseFraction)
        switch loads {
        case let .stack(maxKg, stepKg):
            guard maxKg > 0 else { return unchanged }
            if weightKg > maxKg + toleranceKg { return heaviest(maxKg, reps: reps) }
            guard let stepKg, stepKg > 0 else { return FittedLoad(weightKg: min(weightKg, maxKg), reps: reps) }
            let snapped = min(maxKg, max(stepKg, (weightKg / stepKg).rounded() * stepKg))
            if snapped - weightKg <= allowedRise { return FittedLoad(weightKg: snapped, reps: reps) }
            // The heaviest weight of the stack not above the wanted one: a whole number of steps, and none if the
            // wanted weight is under the first step.
            let steps = (weightKg / stepKg).rounded(.down)
            return steps >= 1 ? FittedLoad(weightKg: steps * stepKg, reps: reps) : unchanged
        case let .fixed(kg):
            let weights = kg.filter { $0 > 0 }.sorted()
            guard let top = weights.last else { return unchanged }
            if weightKg > top + toleranceKg { return heaviest(top, reps: reps) }
            let nearest = weights.min { abs($0 - weightKg) < abs($1 - weightKg) } ?? top
            if nearest - weightKg <= allowedRise { return FittedLoad(weightKg: nearest, reps: reps) }
            return weights.last { $0 <= weightKg }.map { FittedLoad(weightKg: $0, reps: reps) } ?? unchanged
        case .plates, .none:
            return unchanged
        }
    }

    private static func heaviest(_ kg: Double, reps: Int) -> FittedLoad {
        FittedLoad(weightKg: kg, reps: reps + extraRepsAtHeaviest, atHeaviest: true)
    }
}

public extension Suggestion {
    /// The suggestion on a listing's loads. A timed exercise has no rep target to raise.
    func fitted(to loads: ListingLoads) -> Suggestion {
        let fitted = AvailableLoads.fit(weightKg: weightKg, reps: reps, to: loads)
        return Suggestion(weightKg: fitted.weightKg, reps: sec == nil ? fitted.reps : reps, sec: sec, reason: reason)
    }
}
