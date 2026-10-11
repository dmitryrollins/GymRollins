import Foundation
import GymCore
import GymData

/// Builds a new in-progress Workout from a routine: suggested weights, warm-ups for barbell lifts, dumbbell multiplier.
enum SessionPlanner {
    static let barbellEquipment: Set<String> = ["barbell", "olympic barbell", "ez barbell", "smith machine", "trap bar"]

    /// `setOverrides` (by routine item id) are sets edited on Today: those exercises start with exactly them.
    static func start(routine: Routine, profile: Profile, library: ExerciseLibrary, now: Date,
                      history: (String) -> [SessionResult], autoWarmups: Bool = true,
                      setOverrides: [UUID: [WorkoutSet]] = [:]) -> Workout {
        let entries = routine.exercises.map { item in
            let exercise = library.exercise(item.exerciseId)
            if let sets = setOverrides[item.id], !sets.isEmpty {
                return planned(item: item, sets: sets, exercise: exercise)
            }
            return entry(for: item, policy: item.policy ?? routine.policy, profile: profile,
                         exercise: exercise, history: history(item.exerciseId), autoWarmups: autoWarmups)
        }
        return Workout(startedAt: now, routineId: routine.id, name: routine.name, entries: entries)
    }

    /// An entry with sets edited on Today: fresh, not-done copies with the exercise's volume multiplier.
    static func planned(item: RoutineExercise, sets: [WorkoutSet], exercise: Exercise?) -> WorkoutEntry {
        let multiplier = multiplier(for: exercise)
        let fresh = sets.map {
            WorkoutSet(weightKg: $0.weightKg, reps: $0.reps, sec: $0.sec, minutes: $0.minutes,
                       distanceM: $0.distanceM, warmup: $0.warmup, multiplier: multiplier)
        }
        return WorkoutEntry(exerciseId: item.exerciseId, sets: fresh, supersetGroup: item.supersetGroup)
    }

    static func empty(now: Date) -> Workout { Workout(startedAt: now, name: "Workout") }

    /// Picks the barbell/dumbbell rounder and increment and returns the suggested weight/reps/time for an
    /// exercise's next session. Shared by `SessionPlanner.entry` (starting a workout) and `TodayModel` (showing
    /// today's plan) so both agree on the same weight.
    static func suggestion(for item: RoutineExercise, policy: ProgressionPolicy, profile: Profile, exercise: Exercise?,
                           history: [SessionResult]) -> Suggestion {
        let isBarbell = exercise.map { barbellEquipment.contains($0.equipment) } ?? false
        let rounder = LoadRounding.rounder(for: exercise, profile: profile)
        let engine = ProgressionEngine(rounder: rounder, deloadPct: profile.deloadPct)
        let target = ProgressionTarget(sets: item.sets, reps: item.reps, repsMin: item.repsMin, sec: item.sec,
                                       weightKg: item.weightKg ?? 0,
                                       incKg: item.incKg ?? UnitConverter.toKg(isBarbell ? 5 : 2.5, from: .lb),
                                       weightSetAt: item.weightSetAt)
        return engine.suggest(policy: policy, mode: item.mode, target: target, history: history)
    }

    static func entry(for item: RoutineExercise, policy: ProgressionPolicy, profile: Profile, exercise: Exercise?,
                      history: [SessionResult], autoWarmups: Bool = true) -> WorkoutEntry {
        let isBarbell = exercise.map { barbellEquipment.contains($0.equipment) } ?? false
        let multiplier = multiplier(for: exercise)
        let rounder = LoadRounding.rounder(for: exercise, profile: profile)
        let suggestion = suggestion(for: item, policy: policy, profile: profile, exercise: exercise, history: history)
        let working = (0..<item.sets).map { _ in
            WorkoutSet(weightKg: suggestion.weightKg, reps: suggestion.reps, sec: suggestion.sec,
                       multiplier: multiplier)
        }
        let warmups = (isBarbell && autoWarmups)
            ? WarmupGenerator.sets(workingKg: suggestion.weightKg, barKg: profile.barKg, rounder: rounder)
            : []
        return WorkoutEntry(exerciseId: item.exerciseId, sets: warmups + working, supersetGroup: item.supersetGroup)
    }

    /// Volume multiplier for one logged weight: custom exercises say explicitly whether they use
    /// both dumbbells (`bilateral`); library dumbbell and kettlebell exercises are logged per arm (a bell in each
    /// hand, or one arm at a time), so they count twice, except one bell held in both hands.
    static func multiplier(for exercise: Exercise?) -> Double {
        guard let exercise else { return 1 }
        if exercise.isCustom { return exercise.bilateral ? 2 : 1 }
        guard perArmEquipment.contains(exercise.equipment) else { return 1 }
        let name = exercise.name.lowercased()
        return oneBellWords.contains { name.contains($0) } ? 1 : 2
    }

    /// The weight is per arm: the exercise screen says "Per Arm" under it.
    static func isPerArm(_ exercise: Exercise?) -> Bool { multiplier(for: exercise) == 2 }

    private static let perArmEquipment: Set<String> = ["dumbbell", "kettlebell"]
    /// Library movements done with ONE dumbbell or kettlebell held in both hands.
    private static let oneBellWords = ["goblet", "pullover", "waiter", "halo", "figure 8", "side bend",
                                       "two arm military press", "swing"]

    /// Entry for an exercise added mid-workout, with the same mode-aware targets (reps, time or
    /// cardio) as adding it to a routine.
    static func adHocEntry(exerciseId: String, exercise: Exercise?, profile: Profile,
                           history: [SessionResult], autoWarmups: Bool) -> WorkoutEntry {
        let item = exercise.map { RoutineDefaults.item(for: $0, profile: profile) }
            ?? RoutineExercise(exerciseId: exerciseId, sets: 3, reps: 10, repsMin: 8)
        return entry(for: item, policy: item.policy ?? .double, profile: profile, exercise: exercise,
                     history: history, autoWarmups: autoWarmups)
    }

    /// Working weight for a swapped-in exercise: its own progression suggestion when it has
    /// history, otherwise nil (keep the weights already on the entry).
    static func swapWeightKg(exercise: Exercise?, profile: Profile, history: [SessionResult]) -> Double? {
        guard let exercise, !history.isEmpty else { return nil }
        let item = RoutineDefaults.item(for: exercise, profile: profile)
        return suggestion(for: item, policy: item.policy ?? .double, profile: profile, exercise: exercise,
                          history: history).weightKg
    }
}
