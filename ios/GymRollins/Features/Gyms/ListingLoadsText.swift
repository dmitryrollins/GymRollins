import Foundation
import GymCore

/// A listing's loads in words, in the user's unit: "to 250 lb", "44 · 53 lb", "plate-loaded".
enum ListingLoadsText {
    static func text(_ loads: ListingLoads, unit: WeightUnit) -> String? {
        switch loads {
        case let .stack(maxKg, _): "to \(number(maxKg, unit)) \(unit.rawValue)"
        case let .fixed(kg):
            kg.isEmpty ? nil : kg.sorted().map { number($0, unit) }.joined(separator: " \u{00B7} ") + " \(unit.rawValue)"
        case .plates: "plate-loaded"
        case .none: nil
        }
    }

    /// Whole numbers from 10 up (113.4 kg is "113"); small weights keep a decimal so 2.5 stays 2.5.
    private static func number(_ kg: Double, _ unit: WeightUnit) -> String {
        let value = UnitConverter.fromKg(kg, to: unit)
        return value >= 10 ? String(Int(value.rounded())) : WeightFormatter.number(value)
    }
}
