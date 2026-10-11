import Foundation

/// Rounds a load (kg) to what can actually be loaded, in the user's unit: totals on the grid `offset + k × step`.
public struct LoadRounder: Sendable, Equatable, Codable {
    public let unit: WeightUnit
    /// Smallest change of the total load, in `unit` (barbell with 2.5 lb plates = 5 lb).
    public let step: Double
    /// Where the grid starts (in `unit`, `0 ≤ offset < step`): a 45 lb bar with 5 lb the smallest plate loads
    /// 45, 55, … so the grid is 5 + k × 10.
    public let offset: Double

    public init(unit: WeightUnit, step: Double, offset: Double = 0) {
        self.unit = unit
        self.step = step
        self.offset = offset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = try c.decode(WeightUnit.self, forKey: .unit)
        step = try c.decode(Double.self, forKey: .step)
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0
    }

    public static let barbellLb = LoadRounder(unit: .lb, step: 5)
    public static let dumbbellLb = LoadRounder(unit: .lb, step: 2.5)
    public static let barbellKg = LoadRounder(unit: .kg, step: 2.5)

    /// The barbell rounder for a plate inventory: totals are the bar plus pairs of the smallest enabled plate
    /// (unlimited count, so every such total is exactly loadable — `PlateCalculator` finds it). Without plates it
    /// falls back to the unit's standard barbell rounder.
    public static func barbell(inventory: PlateInventory) -> LoadRounder {
        let cents = inventory.plates.map { Int(($0 * 100).rounded()) }.filter { $0 > 0 }
        guard let smallest = cents.min() else { return inventory.unit == .lb ? .barbellLb : .barbellKg }
        let stepCents = 2 * smallest
        let barCents = Int((inventory.bar * 100).rounded())
        let offsetCents = ((barCents % stepCents) + stepCents) % stepCents
        return LoadRounder(unit: inventory.unit, step: Double(stepCents) / 100, offset: Double(offsetCents) / 100)
    }

    public func nearest(_ kg: Double) -> Double { round(kg, .toNearestOrAwayFromZero) }
    public func down(_ kg: Double) -> Double { round(kg, .down) }

    private func round(_ kg: Double, _ rule: FloatingPointRoundingRule) -> Double {
        guard step > 0 else { return kg }
        let value = UnitConverter.fromKg(kg, to: unit) - offset
        // Snap the quotient to remove kg<->lb round-trip float drift before rounding,
        // so exact ties (e.g. 37.5 / 5 == 7.5) round correctly instead of drifting to 7.499999.
        let quotient = ((value / step) * 1e6).rounded() / 1e6
        return UnitConverter.toKg(quotient.rounded(rule) * step + offset, from: unit)
    }
}
