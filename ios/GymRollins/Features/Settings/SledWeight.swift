import Foundation
import GymCore

/// The empty weight of a plate-loaded sled (`Exercise.isSledLoaded`): the plate calculator counts it in place of the
/// bar, since a logged leg press weight includes the sled. Kept on this phone (Bar & Plates), like the rest settings;
/// unset, it is 100 lb, or 45 kg for a kg profile.
enum SledWeight {
    static let key = "sledWeightKg"

    static func kg(_ defaults: UserDefaults, unit: WeightUnit) -> Double {
        defaults.object(forKey: key) as? Double ?? (unit == .lb ? UnitConverter.toKg(100, from: .lb) : 45)
    }

    static func save(kg: Double, _ defaults: UserDefaults) { defaults.set(kg, forKey: key) }

    /// `inventory` with the sled in place of the bar.
    static func inventory(_ inventory: PlateInventory, sledKg: Double) -> PlateInventory {
        PlateInventory(unit: inventory.unit, bar: UnitConverter.fromKg(sledKg, to: inventory.unit),
                       plates: inventory.plates)
    }
}
