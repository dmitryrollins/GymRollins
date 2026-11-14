import GymCore
import SwiftUI

/// A plate's color by its size, after the standard kilogram colors (25 red, 20 blue, 15 yellow, 10 green, 5 white).
/// A pound plate takes its kilogram twin's (45 lb blue, 35 lb yellow, 25 lb green, 10 lb white); change plates are
/// grey (2.5 kg, 5 lb) or silver (smaller), so a small plate never looks like a big one.
enum PlateColor: Equatable {
    case red, blue, yellow, green, white, grey, silver

    static func of(_ plate: Double, unit: WeightUnit) -> PlateColor {
        let kg = UnitConverter.toKg(plate, from: unit)
        if kg >= 22.5 { return .red }
        if kg >= 17.5 { return .blue }
        if kg >= 12.5 { return .yellow }
        if kg >= 7.5 { return .green }
        if kg >= 3.75 { return .white }
        if kg >= 1.75 { return .grey }
        return .silver
    }

    var fill: Color {
        switch self {
        case .red: Color(hex: 0xD8403F)
        case .blue: Color(hex: 0x2F6FE4)
        case .yellow: Color(hex: 0xE6B932)
        case .green: Color(hex: 0x2E9E5B)
        case .white: Color(hex: 0xEDEDF0)
        case .grey: Color(hex: 0x7C7C88)
        case .silver: Color(hex: 0xC4C7D0)
        }
    }

    /// The plate's number, written on it.
    var label: Color {
        switch self {
        case .yellow, .white, .silver: .black
        case .red, .blue, .green, .grey: .white
        }
    }
}
