import GymCore
import GymData

/// Picks the right `LoadRounder` for an exercise: barbell-type equipment loads in fixed
/// per-side-plate increments, everything else (dumbbells, machines, cables, bodyweight, ...)
/// loads in the smaller dumbbell/machine increment.
enum LoadRounding {
    static func isBarbellType(_ equipment: String) -> Bool { Exercise.barbellLoadedEquipment.contains(equipment) }

    static func rounder(for exercise: Exercise?, profile: Profile) -> LoadRounder {
        guard let exercise, isBarbellType(exercise.equipment) else {
            return profile.dumbbellRounder
        }
        return profile.barbellRounder
    }
}
