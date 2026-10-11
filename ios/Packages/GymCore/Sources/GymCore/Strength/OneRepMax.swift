import Foundation

public enum OneRepMaxFormula: String, Codable, Sendable, CaseIterable {
    case epley, brzycki, lombardi
}

public enum OneRepMax {
    /// Estimates above this rep count are unreliable and are not reported.
    public static let maxReps = 12

    public static func estimate(weightKg: Double, reps: Int, formula: OneRepMaxFormula = .epley) -> Double? {
        guard weightKg > 0, (1...maxReps).contains(reps) else { return nil }
        if reps == 1 { return weightKg }
        let r = Double(reps)
        switch formula {
        case .epley: return weightKg * (1 + r / 30)
        case .brzycki: return weightKg * 36 / (37 - r)
        case .lombardi: return weightKg * pow(r, 0.10)
        }
    }
}
