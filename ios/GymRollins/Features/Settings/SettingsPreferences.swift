import Foundation
import GymCore
import GymData

/// Saved locally (not synced): whether `SessionPlanner` adds warm-up sets for barbell lifts when a session starts.
/// Read wherever it takes effect (session creation), written by `SettingsView`'s toggle.
enum WarmupPreferences {
    static let autoWarmupsKey = "autoWarmups"

    static func autoWarmupsEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: autoWarmupsKey) as? Bool ?? true
    }
}

/// Saved locally (not synced): the progression policy a newly created routine starts with.
enum ProgressionDefaultPreference {
    static let key = "defaultProgressionPolicy"

    static func policy(_ defaults: UserDefaults) -> ProgressionPolicy {
        (defaults.string(forKey: key)).flatMap(ProgressionPolicy.init(rawValue:)) ?? .double
    }
}

extension Profile {
    /// A copy with the given fields replaced (immutable-update helper for the Settings screens, each of which
    /// only ever changes a handful of fields at a time).
    // swiftlint:disable:next function_parameter_count
    func with(unit: WeightUnit? = nil, restSec: Int? = nil, warmupRestSec: Int? = nil, deloadPct: Double? = nil,
             barKg: Double? = nil, plateInventory: PlateInventory? = nil, dumbbellStepKg: Double? = nil,
             mcpReadWorkouts: Bool? = nil, mcpReadBody: Bool? = nil, mcpReadPlan: Bool? = nil,
             mcpPropose: Bool? = nil, mcpAutoApply: Bool? = nil) -> Profile {
        Profile(unit: unit ?? self.unit, restSec: restSec ?? self.restSec,
               warmupRestSec: warmupRestSec ?? self.warmupRestSec, heightCm: heightCm, goalWeightKg: goalWeightKg,
               goalDate: goalDate, trainingDays: trainingDays, experience: experience, limits: limits,
               deloadPct: deloadPct ?? self.deloadPct, barKg: barKg ?? self.barKg,
               plateInventory: plateInventory ?? self.plateInventory,
               dumbbellStepKg: dumbbellStepKg ?? self.dumbbellStepKg,
               mcpReadWorkouts: mcpReadWorkouts ?? self.mcpReadWorkouts, mcpReadBody: mcpReadBody ?? self.mcpReadBody,
               mcpReadPlan: mcpReadPlan ?? self.mcpReadPlan, mcpPropose: mcpPropose ?? self.mcpPropose,
               mcpAutoApply: mcpAutoApply ?? self.mcpAutoApply)
    }
}

extension AppEnvironment {
    /// A blank routine for the "new routine" editors (Plan and Today's empty state), starting with the saved
    /// progression default.
    func newRoutineDraft() -> Routine {
        Routine(name: "New routine", policy: ProgressionDefaultPreference.policy(defaults))
    }

    /// Entry for an exercise added mid-workout, honoring the saved warm-up preference like session start does.
    func adHocEntry(exerciseId: String) -> WorkoutEntry {
        SessionPlanner.adHocEntry(exerciseId: exerciseId, exercise: library.exercise(exerciseId), profile: profile,
                                  history: (try? workouts.history(exerciseId: exerciseId, limit: 5)) ?? [],
                                  autoWarmups: WarmupPreferences.autoWarmupsEnabled(defaults))
    }
}
