public enum WeightUnit: String, Codable, Sendable, CaseIterable {
    case kg
    case lb
}

public enum UnitConverter {
    public static let kgPerLb = 0.45359237

    public static func toKg(_ value: Double, from unit: WeightUnit) -> Double {
        unit == .kg ? value : value * kgPerLb
    }

    public static func fromKg(_ kg: Double, to unit: WeightUnit) -> Double {
        unit == .kg ? kg : kg / kgPerLb
    }
}
