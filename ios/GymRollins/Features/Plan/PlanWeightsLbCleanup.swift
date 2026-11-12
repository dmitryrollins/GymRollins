import Foundation
import GymCore
import GymData

/// Plan 38's one-time cleanup of plan weights. Before the pound number, agents sent plan weights in kg and rounded their
/// conversion (45 lb as 20.3 kg, which shows as 44.8 lb). On the first launch in lb, every plan weight without a pound
/// number gets one: snapped to its exercise's grid (the plan stepper's rounder, `LoadRounding`), or kept as it is when
/// its kg already is a ½ lb number. Changed routines are saved, which marks them to sync. Logged history isn't touched.
enum PlanWeightsLbCleanup {
    /// Set in UserDefaults once the cleanup has run.
    static let flagKey = "planWeightsLbV1"

    /// Runs the cleanup unless it has run before or the unit is kg (it waits for the first launch in lb). Returns how
    /// many routines changed.
    @MainActor
    static func runOnce(routines: RoutineRepository, profile: Profile, library: ExerciseLibrary,
                        defaults: UserDefaults) throws -> Int {
        guard profile.unit == .lb, !defaults.bool(forKey: flagKey) else { return 0 }
        let rounder = { LoadRounding.rounder(for: library.exercise($0), profile: profile) }
        let changed = try routines.all().compactMap { cleaned($0, rounder: rounder) }
        for routine in changed { try routines.upsert(routine) }
        defaults.set(true, forKey: flagKey)
        return changed.count
    }

    /// `routine` with each plan weight given a pound number (`cleaned(_:rounder:)`, with the exercise's rounder); nil
    /// when none changes.
    static func cleaned(_ routine: Routine, rounder: (String) -> LoadRounder) -> Routine? {
        let items = routine.exercises.map { item in
            item.weight.map { cleaned($0, rounder: rounder(item.exerciseId)) }.map(item.withPlanWeight) ?? item
        }
        guard items != routine.exercises else { return nil }
        return Routine(id: routine.id, name: routine.name, emoji: routine.emoji, policy: routine.policy,
                       paused: routine.paused, exercises: items)
    }

    /// A plan weight with a pound number. One that has one, or weighs nothing, stays. A kg that already is a ½ lb number
    /// (20.41 kg, 45 lb) keeps its kg and gains that number, so a weight chosen in pounds never moves. Any other kg goes
    /// to the nearest weight on `rounder`'s grid, which in lb is a pound number; without one (no grid), to the nearest
    /// ½ lb.
    static func cleaned(_ weight: PoundWeight, rounder: LoadRounder) -> PoundWeight {
        guard weight.lb == nil, weight.kg > 0 else { return weight }
        let halfPound = PoundWeight.snappedToHalfPound(kg: weight.kg)
        if let lb = PoundWeight.agreeing(halfPound.lb, kg: weight.kg) { return PoundWeight(kg: weight.kg, lb: lb) }
        let onGrid = rounder.nearestWeight(weight.kg)
        return onGrid.lb != nil && onGrid.kg > 0 ? onGrid : halfPound
    }
}

private extension RoutineExercise {
    /// This item with `weight` as its plan weight. Unlike `with(weight:setAt:)` it keeps `weightSetAt`: the cleanup
    /// isn't a newly planned weight, so progression goes on as before.
    func withPlanWeight(_ weight: PoundWeight) -> RoutineExercise {
        RoutineExercise(id: id, exerciseId: exerciseId, sets: sets, reps: reps, repsMin: repsMin, sec: sec,
                        weightKg: weight.kg, weightLb: weight.lb, mode: mode, policy: policy, incKg: incKg,
                        supersetGroup: supersetGroup, weightSetAt: weightSetAt, fixedWeightKg: fixedWeightKg,
                        fixedWeightLb: fixedWeightLb)
    }
}
