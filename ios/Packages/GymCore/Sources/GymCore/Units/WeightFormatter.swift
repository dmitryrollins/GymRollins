import Foundation

public enum WeightFormatter {
    /// "140 lb (63.5 kg)" when `unit` is lb; "20 kg (44.1 lb)" when kg. With `lb`, the weight's pound number
    /// (`PoundWeight`), the pounds show that number.
    public static func format(kg: Double, lb: Double? = nil, unit: WeightUnit, includeSecondary: Bool = true) -> String {
        let other: WeightUnit = unit == .kg ? .lb : .kg
        let primary = "\(number(kg: kg, lb: lb, unit: unit)) \(unit.rawValue)"
        guard includeSecondary else { return primary }
        return "\(primary) (\(number(kg: kg, lb: lb, unit: other)) \(other.rawValue))"
    }

    /// A set or plan weight's number in `unit`: its pound number in lb when it has one, else converted from kg
    /// (`UnitConverter.fromKg(_:lb:to:)`), formatted as `number(_:)`.
    public static func number(kg: Double, lb: Double?, unit: WeightUnit) -> String {
        number(UnitConverter.fromKg(kg, lb: lb, to: unit))
    }

    /// At most one decimal, trailing ".0" removed.
    public static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }
}
