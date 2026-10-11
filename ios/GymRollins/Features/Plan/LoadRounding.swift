import GymCore
import GymData

/// Picks the right `LoadRounder` for an exercise: barbell-type equipment loads in fixed
/// per-side-plate increments, everything else (dumbbells, machines, cables, bodyweight, ...)
/// loads in the smaller dumbbell/machine increment.
enum LoadRounding {
    /// Equipment that's loaded as a fixed bar plus plates, so it only moves in barbell increments.
    private static let barbellEquipment: Set<String> = [
        "barbell", "olympic barbell", "ez barbell", "smith machine", "trap bar"
    ]

    static func isBarbellType(_ equipment: String) -> Bool { barbellEquipment.contains(equipment) }

    static func rounder(for exercise: Exercise?, profile: Profile) -> LoadRounder {
        guard let exercise, isBarbellType(exercise.equipment) else {
            return profile.dumbbellRounder
        }
        return profile.barbellRounder
    }
}
