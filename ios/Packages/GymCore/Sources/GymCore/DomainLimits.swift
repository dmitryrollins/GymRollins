import Foundation

/// Value limits shared by local validation and the database CHECK constraints
/// (supabase/migrations/*_schema.sql, *_security_fixes.sql). Anything saved locally must fit these, or the row
/// would be rejected when it syncs.
public enum DomainLimits {
    // Routines
    public static let routineNameMax = 40
    public static let routineExercisesMax = 20
    // Custom exercises and workouts
    public static let customExerciseNameMax = 80
    public static let workoutNameMax = 80
    // Workout sets
    public static let setWeightKg: ClosedRange<Double> = 0...1_000
    public static let setReps: ClosedRange<Int> = 0...1_000
    public static let setSeconds: ClosedRange<Int> = 0...86_400
    public static let setMinutes: ClosedRange<Double> = 0...1_440
    public static let setDistanceM: ClosedRange<Double> = 0...1_000_000
    // Body
    public static let bodyweightKg: ClosedRange<Double> = 30...300
    public static let bodyFatPct: ClosedRange<Double> = 3...60
    // Profile
    public static let restSec: ClosedRange<Int> = 0...900
    public static let heightCm: ClosedRange<Double> = 100...250
    public static let goalWeightKg: ClosedRange<Double> = 30...300
    public static let trainingDays: ClosedRange<Int> = 1...7
    public static let limitsTextMax = 500
    public static let deloadPct: ClosedRange<Double> = 0...0.5
    /// Optional, for strength levels only (profiles.birth_year).
    public static let birthYear: ClosedRange<Int> = 1900...2100
    // Weekly hard-set targets per muscle group (muscle_targets.min_sets / max_sets)
    public static let weeklySetTarget: ClosedRange<Int> = 0...50

    /// User-facing reason the routine can't be saved, or nil when it fits.
    public static func routineViolation(_ routine: Routine) -> String? {
        let name = routine.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give the routine a name." }
        if name.count > routineNameMax { return "Routine names can be up to \(routineNameMax) characters." }
        if routine.exercises.count > routineExercisesMax {
            return "A routine can have up to \(routineExercisesMax) exercises."
        }
        return nil
    }

    public static func customExerciseNameViolation(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Name required" }
        if trimmed.count > customExerciseNameMax { return "Names can be up to \(customExerciseNameMax) characters." }
        return nil
    }

    public static func bodyweightViolation(weightKg: Double, bodyFatPct fat: Double?) -> String? {
        if !bodyweightKg.contains(weightKg) {
            return "Enter a weight between \(Int(bodyweightKg.lowerBound)) and \(Int(bodyweightKg.upperBound)) kg"
        }
        if let fat, !bodyFatPct.contains(fat) {
            return "Enter a body fat between \(Int(bodyFatPct.lowerBound)) and \(Int(bodyFatPct.upperBound))%"
        }
        return nil
    }

    // swiftlint:disable:next function_parameter_count
    public static func profileViolation(restSec rest: Int, warmupRestSec: Int, heightCm height: Double?,
                                        goalWeightKg goal: Double?, trainingDays days: Int, limits: String,
                                        deloadPct deload: Double) -> String? {
        if !restSec.contains(rest) || !restSec.contains(warmupRestSec) {
            return "Rest times can be up to \(restSec.upperBound / 60) minutes."
        }
        if let height, !heightCm.contains(height) { return "Height must be 100–250 cm." }
        if let goal, !goalWeightKg.contains(goal) { return "Goal weight must be 30–300 kg." }
        if !trainingDays.contains(days) { return "Training days must be 1–7." }
        if limits.count > limitsTextMax { return "Limits can be up to \(limitsTextMax) characters." }
        if !deloadPct.contains(deload) { return "Deload must be 0–50%." }
        return nil
    }
}
