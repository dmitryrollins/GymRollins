import Foundation
import GymCore
import GymData

/// The Bar & Plates fields as typed, in the profile's unit. Values are shown with up to 3 decimals (1.25 stays
/// 1.25) and parsed with `LocalizedNumber` ("1,25" works); `updatedProfile` is nil when nothing changed, so
/// opening the screen never writes the profile.
struct BarAndPlatesForm: Equatable {
    var barText: String
    var dumbbellStepText: String
    var available: Set<Double>

    static let lbPlates: [Double] = [45, 35, 25, 10, 5, 2.5]
    static let kgPlates: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]
    static func standardPlates(_ unit: WeightUnit) -> [Double] { unit == .lb ? lbPlates : kgPlates }

    enum Invalid: Error, Equatable { case nonPositive }

    init(barText: String, dumbbellStepText: String, available: Set<Double>) {
        self.barText = barText
        self.dumbbellStepText = dumbbellStepText
        self.available = available
    }

    init(profile: Profile) {
        barText = Self.format(profile.plateInventory.bar)
        dumbbellStepText = Self.format(UnitConverter.fromKg(profile.dumbbellStepKg, to: profile.unit))
        available = Set(profile.plateInventory.plates)
    }

    /// Up to 3 decimals, trailing zeros trimmed: 45 → "45", 1.25 → "1.25", 2.2046 → "2.205".
    static func format(_ value: Double) -> String {
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// The profile with these values, nil when they equal what `profile` already holds; throws when the bar or
    /// dumbbell step isn't a number above zero.
    func updatedProfile(from profile: Profile) throws(Invalid) -> Profile? {
        guard let bar = LocalizedNumber.parse(barText), bar > 0,
              let step = LocalizedNumber.parse(dumbbellStepText), step > 0 else { throw .nonPositive }
        let unit = profile.unit
        let plates = Self.standardPlates(unit).filter(available.contains).sorted(by: >)
        let currentStep = UnitConverter.fromKg(profile.dumbbellStepKg, to: unit)
        let unchanged = profile.plateInventory.unit == unit
            && abs(profile.plateInventory.bar - bar) < 0.0005
            && abs(currentStep - step) < 0.0005
            && profile.plateInventory.plates.sorted(by: >) == plates
        guard !unchanged else { return nil }
        return profile.with(barKg: UnitConverter.toKg(bar, from: unit),
                            plateInventory: PlateInventory(unit: unit, bar: bar, plates: plates),
                            dumbbellStepKg: UnitConverter.toKg(step, from: unit))
    }
}
