import Foundation
import GymCore
import GymData

/// Builds a new in-progress Workout from a routine: suggested weights, warm-ups for barbell lifts, dumbbell multiplier.
enum SessionPlanner {
    /// `setOverrides` (by routine item id) are sets edited on Today: those exercises start with exactly them. `loads`
    /// gives the current gym's listing loads for an exercise (nil: no gym, or nothing to fit to), and `loadListing` the
    /// listing those loads come from; both are stored on the workout so history knows where it was done.
    static func start(routine: Routine, profile: Profile, library: ExerciseLibrary, now: Date,
                      history: (String) -> [SessionResult], autoWarmups: Bool = true,
                      setOverrides: [UUID: [WorkoutSet]] = [:],
                      loads: (String) -> ListingLoads? = { _ in nil }, gymId: UUID? = nil,
                      loadListing: (String) -> UUID? = { _ in nil }) -> Workout {
        let entries = routine.exercises.map { item in
            let exercise = library.exercise(item.exerciseId)
            let built: WorkoutEntry
            if let sets = setOverrides[item.id], !sets.isEmpty {
                built = planned(item: item, sets: sets, exercise: exercise)
            } else {
                built = entry(for: item, policy: item.policy ?? routine.policy, profile: profile,
                              exercise: exercise, history: history(item.exerciseId), autoWarmups: autoWarmups,
                              loads: loads(item.exerciseId))
            }
            return gymId == nil ? built : built.with(gymListingId: loadListing(item.exerciseId))
        }
        return Workout(startedAt: now, routineId: routine.id, name: routine.name, entries: entries, gymId: gymId)
    }

    /// An entry with sets edited on Today: fresh, not-done copies (weights with their pound numbers) with the exercise's
    /// volume multiplier.
    static func planned(item: RoutineExercise, sets: [WorkoutSet], exercise: Exercise?) -> WorkoutEntry {
        let multiplier = multiplier(for: exercise)
        let fresh = sets.map {
            WorkoutSet(weightKg: $0.weightKg, weightLb: $0.weightLb, reps: $0.reps, sec: $0.sec, minutes: $0.minutes,
                       distanceM: $0.distanceM, warmup: $0.warmup, multiplier: multiplier)
        }
        return WorkoutEntry(exerciseId: item.exerciseId, sets: fresh, supersetGroup: item.supersetGroup)
    }

    static func empty(now: Date, gymId: UUID? = nil) -> Workout { Workout(startedAt: now, name: "Workout", gymId: gymId) }

    /// Picks the barbell/dumbbell rounder and increment and returns the suggested weight/reps/time for an
    /// exercise's next session. Shared by `SessionPlanner.entry` (starting a workout) and `TodayModel` (showing
    /// today's plan) so both agree on the same weight. With `loads`, the weight is fitted to what the gym offers. The
    /// plan's and the fixed weight's pound numbers go with them, so the suggestion keeps its own.
    static func suggestion(for item: RoutineExercise, policy: ProgressionPolicy, profile: Profile, exercise: Exercise?,
                           history: [SessionResult], loads: ListingLoads? = nil) -> Suggestion {
        let isBarbell = exercise?.isBarbellLoaded ?? false
        let rounder = LoadRounding.rounder(for: exercise, profile: profile)
        let engine = ProgressionEngine(rounder: rounder, deloadPct: profile.deloadPct)
        let target = ProgressionTarget(sets: item.sets, reps: item.reps, repsMin: item.repsMin, sec: item.sec,
                                       weightKg: item.weightKg ?? 0, weightLb: item.weightLb,
                                       incKg: item.incKg ?? UnitConverter.toKg(isBarbell ? 5 : 2.5, from: .lb),
                                       weightSetAt: item.weightSetAt, fixedWeightKg: item.fixedWeightKg,
                                       fixedWeightLb: item.fixedWeightLb)
        let suggestion = engine.suggest(policy: policy, mode: item.mode, target: target, history: history)
        return loads.map(suggestion.fitted(to:)) ?? suggestion
    }

    static func entry(for item: RoutineExercise, policy: ProgressionPolicy, profile: Profile, exercise: Exercise?,
                      history: [SessionResult], autoWarmups: Bool = true, loads: ListingLoads? = nil) -> WorkoutEntry {
        let isBarbell = exercise?.isBarbellLoaded ?? false
        let multiplier = multiplier(for: exercise)
        let rounder = LoadRounding.rounder(for: exercise, profile: profile)
        let suggestion = suggestion(for: item, policy: policy, profile: profile, exercise: exercise, history: history,
                                    loads: loads)
        let working = (0..<item.sets).map { _ in
            WorkoutSet(weightKg: suggestion.weightKg, weightLb: suggestion.weightLb, reps: suggestion.reps,
                       sec: suggestion.sec, multiplier: multiplier)
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
                           history: [SessionResult], autoWarmups: Bool, loads: ListingLoads? = nil) -> WorkoutEntry {
        let item = exercise.map { RoutineDefaults.item(for: $0, profile: profile) }
            ?? RoutineExercise(exerciseId: exerciseId, sets: 3, reps: 10, repsMin: 8)
        return entry(for: item, policy: item.policy ?? .double, profile: profile, exercise: exercise,
                     history: history, autoWarmups: autoWarmups, loads: loads)
    }

    /// What a swapped-in exercise's undone working sets move to. With history it's the exercise's own progression
    /// weight, which the gym's loads (if any) fit one set at a time; each set keeps its own reps (only the gym's
    /// "past the heaviest" rule adds some). Without history, each set's current weight is fitted to the gym's loads and
    /// the reps stay (a never-logged exercise has no progression to reward); with neither, the sets are left alone.
    static func swapTarget(exercise: Exercise?, profile: Profile, history: [SessionResult],
                           loads: ListingLoads? = nil) -> SwapTarget {
        if let exercise, !history.isEmpty {
            let item = RoutineDefaults.item(for: exercise, profile: profile)
            let next = suggestion(for: item, policy: item.policy ?? .double, profile: profile, exercise: exercise,
                                  history: history)
            return .suggested(weight: next.weight, loads: loads, timed: next.sec != nil)
        }
        return loads.map(SwapTarget.fit) ?? .keep
    }
}

/// A set's weight (kg and pound number) and reps after a swap.
struct ResolvedSet: Equatable {
    let weight: PoundWeight
    let reps: Int

    init(weight: PoundWeight, reps: Int) {
        self.weight = weight
        self.reps = reps
    }

    /// A weight in kg only: no pound number.
    init(weightKg: Double, reps: Int) {
        self.init(weight: PoundWeight(kg: weightKg, lb: nil), reps: reps)
    }

    var weightKg: Double { weight.kg }
}

/// How `WorkoutSession.swap` retargets the undone working sets. Every weight keeps its pound number: a kept or fitted
/// weight its own (`AvailableLoads.fit`), a suggested one the suggestion's.
enum SwapTarget: Equatable {
    case keep
    /// The new exercise's progression weight, fitted per set to `loads` when the gym has them. A timed exercise's
    /// sets keep their reps.
    case suggested(weight: PoundWeight, loads: ListingLoads?, timed: Bool)
    /// No history: each set's own weight fitted to the gym's loads, reps unchanged.
    case fit(ListingLoads)

    func resolved(for set: WorkoutSet) -> ResolvedSet {
        switch self {
        case .keep: ResolvedSet(weight: set.weight, reps: set.reps)
        case let .suggested(weight, loads, timed):
            Self.suggested(weight: weight, loads: loads, timed: timed, set: set)
        case let .fit(loads):
            ResolvedSet(weight: AvailableLoads.fit(weightKg: set.weightKg, weightLb: set.weightLb, reps: set.reps,
                                                   to: loads).weight,
                        reps: set.reps)
        }
    }

    private static func suggested(weight: PoundWeight, loads: ListingLoads?, timed: Bool,
                                  set: WorkoutSet) -> ResolvedSet {
        guard let loads else { return ResolvedSet(weight: weight, reps: set.reps) }
        let fitted = AvailableLoads.fit(weightKg: weight.kg, weightLb: weight.lb, reps: set.reps, to: loads)
        return ResolvedSet(weight: fitted.weight, reps: timed ? set.reps : fitted.reps)
    }
}
