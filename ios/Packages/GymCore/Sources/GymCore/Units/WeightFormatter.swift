import Foundation

public enum WeightFormatter {
    /// "140 lb (63.5 kg)" when `unit` is lb; "20 kg (44.1 lb)" when kg.
    public static func format(kg: Double, unit: WeightUnit, includeSecondary: Bool = true) -> String {
        let other: WeightUnit = unit == .kg ? .lb : .kg
        let primary = "\(number(UnitConverter.fromKg(kg, to: unit))) \(unit.rawValue)"
        guard includeSecondary else { return primary }
        return "\(primary) (\(number(UnitConverter.fromKg(kg, to: other))) \(other.rawValue))"
    }

    /// At most one decimal, trailing ".0" removed.
    public static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }
}
