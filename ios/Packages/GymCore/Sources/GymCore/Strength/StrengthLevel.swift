import Foundation

public enum StrengthLevel: String, CaseIterable, Codable, Sendable, Comparable, Identifiable {
    case beginner, novice, intermediate, advanced, elite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .beginner: "Beginner"
        case .novice: "Novice"
        case .intermediate: "Intermediate"
        case .advanced: "Advanced"
        case .elite: "Elite"
        }
    }

    public var next: StrengthLevel? {
        let all = Self.allCases
        guard let i = all.firstIndex(of: self), i + 1 < all.count else { return nil }
        return all[i + 1]
    }

    public static func < (lhs: StrengthLevel, rhs: StrengthLevel) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Where one lift sits against the raw-competitor table.
public struct StrengthAssessment: Equatable, Sendable {
    public let lift: StrengthLift
    public let e1RMKg: Double
    public let bodyweightKg: Double
    public let level: StrengthLevel
    /// 0…100 among raw competitors of the same sex, age group and bodyweight (below the table's first percentile
    /// it falls linearly to 0 at 0 kg; above the last it is 100).
    public let percentile: Double
    /// Each level's threshold (kg), in level order; `beginner` is 0.
    public let thresholds: [StrengthLevel: Double]
    public let next: StrengthLevel?
    public let nextTargetKg: Double?
    /// Share of the way from this level's threshold to the next one's (1 at Elite).
    public let progress: Double
    /// The table's first and last percentile (for "under 1 %" / "over 99 %").
    public let percentileRange: ClosedRange<Double>

    public var gapKg: Double? { nextTargetKg.map { max(0, $0 - e1RMKg) } }

    /// "under 1%", "23%", "over 99%" — share of raw competitors this lift beats.
    public var percentileText: String {
        if percentile < percentileRange.lowerBound { return "under \(Int(percentileRange.lowerBound))%" }
        if percentile > percentileRange.upperBound { return "over \(Int(percentileRange.upperBound))%" }
        return "\(Int(percentile.rounded(.down)))%"
    }
}

public enum StrengthLevelCalculator {
    /// Nil when the table has no curve for this sex/age/lift, or the inputs aren't positive.
    // swiftlint:disable:next function_parameter_count
    public static func assess(standards: StrengthStandards, lift: StrengthLift, e1RMKg: Double, bodyweightKg: Double,
                              sex: ProfileSex, age: Int) -> StrengthAssessment? {
        guard e1RMKg > 0, bodyweightKg > 0,
              let curve = standards.curve(sex: sex, lift: lift, age: age, bodyweightKg: bodyweightKg) else { return nil }
        let thresholds = thresholds(standards: standards, curve: curve)
        // Exactly on a threshold counts as reaching it (tolerance for kg <-> lb float noise).
        let level = StrengthLevel.allCases.last { (thresholds[$0] ?? .infinity) <= e1RMKg + 1e-9 } ?? .beginner
        let next = level.next
        let nextTarget = next.flatMap { thresholds[$0] }
        let floor = thresholds[level] ?? 0
        let progress = nextTarget.map { $0 > floor ? min(1, max(0, (e1RMKg - floor) / ($0 - floor))) : 1 } ?? 1
        return StrengthAssessment(
            lift: lift, e1RMKg: e1RMKg, bodyweightKg: bodyweightKg, level: level,
            percentile: percentile(of: e1RMKg, curve: curve, percentiles: standards.percentiles),
            thresholds: thresholds, next: next, nextTargetKg: nextTarget, progress: progress,
            percentileRange: (standards.percentiles.first ?? 0)...(standards.percentiles.last ?? 100))
    }

    /// `fraction × curve(percentile)` per level, forced non-decreasing in level order.
    static func thresholds(standards: StrengthStandards, curve: [Double]) -> [StrengthLevel: Double] {
        var out: [StrengthLevel: Double] = [:]
        var floor = 0.0
        for anchor in standards.levels {
            guard let level = StrengthLevel(rawValue: anchor.id) else { continue }
            let kg = anchor.fraction * value(at: anchor.percentile, curve: curve, percentiles: standards.percentiles)
            floor = max(floor, kg)
            out[level] = floor
        }
        return out
    }

    /// The curve's kg at percentile `p` (linear between table percentiles, clamped at the ends).
    static func value(at p: Double, curve: [Double], percentiles: [Double]) -> Double {
        guard let first = percentiles.first, let last = percentiles.last else { return 0 }
        if p <= first { return curve[0] }
        if p >= last { return curve[curve.count - 1] }
        let hi = percentiles.firstIndex { $0 >= p }!
        let lo = hi - 1
        let t = (p - percentiles[lo]) / (percentiles[hi] - percentiles[lo])
        return curve[lo] + (curve[hi] - curve[lo]) * t
    }

    /// Inverse of `value(at:)`: the percentile a lift reaches. Below the first point it falls linearly to 0 at
    /// 0 kg; at or above the last it is 100. Flat stretches resolve to their highest percentile.
    static func percentile(of kg: Double, curve: [Double], percentiles: [Double]) -> Double {
        guard let firstKg = curve.first, let lastKg = curve.last, let firstP = percentiles.first else { return 0 }
        if kg < firstKg { return firstKg > 0 ? firstP * kg / firstKg : 0 }
        if kg >= lastKg { return 100 }
        let hi = curve.firstIndex { $0 > kg }!
        let lo = hi - 1
        let t = (kg - curve[lo]) / (curve[hi] - curve[lo])
        return percentiles[lo] + (percentiles[hi] - percentiles[lo]) * t
    }
}
