import Foundation
import GymCore
import Testing
@testable import GymRollins

@Suite struct TodayPlanSharedTests {
    private let day = "2026-11-01"

    private let item = RoutineExercise(exerciseId: "bb", sets: 3, reps: 10, repsMin: 8)

    @Test func isABuiltPlanNamedSharedWorkout() {
        let plan = TodayPlan.shared(items: [item], day: day)
        #expect(plan.kind == .built)
        #expect(plan.title == "Shared workout")
        #expect(plan.exercises == [item])
        #expect(plan.day == day)
        #expect(plan.routineToStart?.name == "Shared workout")
    }

    @Test func survivesAReload() throws {
        let plan = TodayPlan.shared(items: [item], day: day)
        let data = try JSONEncoder().encode(plan)
        let loaded = try JSONDecoder().decode(TodayPlan.self, from: data)
        #expect(loaded == plan)
    }

    @Test func shareSourcesFollowEditedSets() {
        let edited = RoutineExercise(exerciseId: "db", sets: 3, reps: 10)
        let plan = TodayPlan.built(name: "Built", items: [item, edited], day: day)
            .editingSets(edited.id, [WorkoutSet(weightKg: 20, reps: 15, warmup: true), WorkoutSet(weightKg: 30, reps: 6),
                                     WorkoutSet(weightKg: 30, reps: 5)])
        #expect(plan.shareSources == [
            SharedWorkout.Source(exerciseId: "bb", sets: 3, target: .reps(min: 8, max: 10), group: nil),
            SharedWorkout.Source(exerciseId: "db", sets: 2, target: .reps(min: nil, max: 6), group: nil),
        ])
    }

    /// Through the store, as Today reads it: a stored shared plan comes back exactly as sent.
    @Test func aStoredSharedPlanIsUnchanged() throws {
        let defaults = try #require(UserDefaults(suiteName: "TodayPlanSharedTests.\(UUID())"))
        let store = TodayPlanStore(defaults: defaults)
        let plan = TodayPlan.shared(items: [item.with(fixedWeightKg: 40)], day: day)
        store.save(plan)
        let loaded = try #require(store.load(day: day, routines: [], scheduled: nil))
        #expect(loaded == plan)
        #expect(loaded.exercises.first?.fixedWeightKg == 40)
    }
}
