import Foundation
import GymCore
import GymData

/// Pure parsing/building for `ProfileSetupView`: localized decimals ("82,5" and "82.5"), and optional fields that
/// are either empty (nil) or valid — never silently dropped when mistyped.
struct ProfileSetupInput: Equatable {
    struct Invalid: Error, Equatable { let message: String }

    let bodyweightKg: Double
    let heightCm: Double?
    let goalWeightKg: Double?

    static func parse(bodyweight: String, height: String, goalWeight: String,
                      unit: WeightUnit) -> Result<ProfileSetupInput, Invalid> {
        guard let bodyweight = LocalizedNumber.parse(bodyweight) else {
            return .failure(Invalid(message: "Enter your bodyweight."))
        }
        guard let height = optional(height) else { return .failure(Invalid(message: "Enter a valid height in cm.")) }
        guard let goal = optional(goalWeight) else { return .failure(Invalid(message: "Enter a valid goal weight.")) }
        return .success(ProfileSetupInput(bodyweightKg: UnitConverter.toKg(bodyweight, from: unit),
                                          heightCm: height, goalWeightKg: goal.map { UnitConverter.toKg($0, from: unit) }))
    }

    /// `.some(nil)` for an empty field, `.some(value)` for a number, `nil` for text that isn't a number.
    private static func optional(_ text: String) -> Double?? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .some(nil) }
        return LocalizedNumber.parse(text).map { .some($0) }
    }
}

extension Profile {
    /// A copy switched to `unit` with that unit's standard plate inventory and its standard bar (20 kg / 45 lb),
    /// keeping `barKg` in step with the inventory the plate calculator uses.
    func withStandardEquipment(for unit: WeightUnit) -> Profile {
        let inventory: PlateInventory = unit == .lb ? .standardLb : .standardKg
        return with(unit: unit, barKg: UnitConverter.toKg(inventory.bar, from: inventory.unit), plateInventory: inventory)
    }
}

/// Saves the onboarding weigh-in under a stable id, so revisiting Profile Setup (Back, then Continue again)
/// updates the one observation instead of adding another.
@MainActor
enum OnboardingWeighIn {
    /// Upserts the weigh-in and returns the id to reuse next time.
    @discardableResult
    static func save(weightKg: Double, date: Date, reusing id: UUID?, in body: BodyRepository) throws -> UUID {
        let id = id ?? UUID()
        try body.upsert(BodyweightEntry(id: id, date: date, weightKg: weightKg))
        return id
    }
}
