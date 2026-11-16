import Foundation

/// Value limits shared by local validation and the database CHECK constraints and caps
/// (server/migrations/0002_app_schema.sql, 0005_gyms_photos.sql, 0010_account_caps.sql). Anything saved locally must
/// fit these, or the row would be rejected when it syncs.
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
    // Gyms and equipment
    public static let gymNameMax = 120
    public static let gymAddressMax = 300
    public static let listingQuantity: ClosedRange<Int> = 1...50
    public static let listingNotesMax = 280
    public static let itemBrandMax = 60
    public static let itemModelMax = 80
    public static let listingStackKg: ClosedRange<Double> = 0.25...1_000
    public static let listingStepKg: ClosedRange<Double> = 0.25...50
    public static let listingFixedWeightsMax = 60
    public static let listingFixedKg: ClosedRange<Double> = 0.25...500
    public static let privateGymsMax = 100
    public static let privateListingsMax = 1_000
    public static let gymActiveListingsMax = 300
    // Apple Health activities: outside workouts and days of activity (server/migrations/0013_health_activities.sql)
    public static let activityDurationS: ClosedRange<Double> = 0...86_400
    public static let activityKcal: ClosedRange<Double> = 0...20_000
    public static let activityDistanceM: ClosedRange<Double> = 0...1_000_000
    public static let heartRateBpm: ClosedRange<Int> = 20...250
    public static let activityPowerW: ClosedRange<Int> = 0...2_500
    public static let activityCadenceRpm: ClosedRange<Int> = 0...250
    public static let daySteps: ClosedRange<Int> = 0...200_000
    public static let dayExerciseMin: ClosedRange<Int> = 0...1_440
    public static let dayStandH: ClosedRange<Int> = 0...24
    /// An outside workout's kind slug and source name.
    public static let activityTextMax = 100
    // Storage per account, deleted rows included (server/migrations/0010_account_caps.sql)
    public static let workoutsMax = 10_000
    public static let bodyweightsMax = 20_000
    public static let routinesMax = 200
    public static let customExercisesMax = 1_000
    public static let pendingProposalsMax = 100
    public static let proposalsMax = 5_000
    public static let exercisePrefsMax = 2_000
    public static let privateGymsTotalMax = 500
    public static let privateListingsTotalMax = 5_000
    // Kept in health_rows, not account_rows (server/migrations/0013_health_activities.sql)
    public static let healthActivitiesMax = 20_000
    public static let activityDaysMax = 5_000
    // Exercises and sets logged per account, deleted workouts included (server/src/sync/workouts.ts keeps the counts)
    public static let accountEntriesMax = 50_000
    public static let accountSetsMax = 250_000
    // One workout, as each save stores it (server/src/sync/workouts.ts)
    public static let workoutEntriesMax = 50
    public static let entrySetsMax = 50
    // Daily limits per user, enforced by the server functions
    public static let dailyGymCreations = 10
    public static let dailyShares = 30
    public static let dailyConfirmations = 100
    public static let dailyPhotoUploads = 60
    public static let dailyReports = 20
    public static let dailyBlocks = 20
    public static let dailyUnblocks = 3
    public static let reportNoteMax = 280

    /// User-facing reason the routine can't be saved, or nil when it fits.
    public static func routineViolation(_ routine: Routine) -> String? {
        let name = routine.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give the workout a name." }
        if name.count > routineNameMax { return "Workout names can be up to \(routineNameMax) characters." }
        if routine.exercises.count > routineExercisesMax {
            return "A workout can have up to \(routineExercisesMax) exercises."
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

    /// Why an outside workout read from Health can't be stored, or nil. One that doesn't fit is skipped on import, never
    /// clamped.
    public static func healthActivityViolation(_ a: HealthActivity) -> String? {
        if !(1...activityTextMax).contains(a.kind.count) { return "Kind must be 1–\(activityTextMax) characters." }
        if !(1...activityTextMax).contains(a.sourceName.count) {
            return "Source names can be 1–\(activityTextMax) characters."
        }
        if a.endedAt < a.startedAt { return "A workout can't end before it starts." }
        if !activityDurationS.contains(a.durationS) { return "Duration must be 0–24 hours." }
        if let kcal = a.kcal, !activityKcal.contains(kcal) { return "Calories must be 0–20,000 kcal." }
        if let total = a.totalKcal, !activityKcal.contains(total) { return "Total calories must be 0–20,000 kcal." }
        if let distance = a.distanceM, !activityDistanceM.contains(distance) { return "Distance must be 0–1,000 km." }
        if [a.avgHr, a.maxHr].contains(where: { $0.map { !heartRateBpm.contains($0) } ?? false }) {
            return "Heart rate must be 20–250 bpm."
        }
        if let power = a.avgPowerW, !activityPowerW.contains(power) { return "Average power must be 0–2,500 W." }
        if let cadence = a.avgCadenceRpm, !activityCadenceRpm.contains(cadence) {
            return "Average cadence must be 0–250 rpm."
        }
        return nil
    }

    /// Why a day of activity can't be stored, or nil. Like an outside workout, one that doesn't fit is skipped.
    public static func activityDayViolation(_ d: ActivityDay) -> String? {
        if !daySteps.contains(d.steps) { return "Steps must be 0–200,000." }
        if !activityKcal.contains(d.moveKcal) { return "Move must be 0–20,000 kcal." }
        if !dayExerciseMin.contains(d.exerciseMin) { return "Exercise must be 0–1,440 minutes." }
        if let stand = d.standH, !dayStandH.contains(stand) { return "Stand must be 0–24 hours." }
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
