import Foundation
import GymCore
import Testing
@testable import GymRollins

@Suite struct TodayPlanSharedTests {
    private let day = "2026-11-01"
    private static let kinds = ["barbell", "dumbbells"].map {
        EquipmentKind(id: $0, name: $0, category: .freeWeight, load: .none)
    }
    private static let exercises = [
        Exercise(id: "bb", name: "bb", bodyPart: "chest", equipment: "barbell", target: "pectorals", secondary: ["triceps"]),
        Exercise(id: "db", name: "db", bodyPart: "chest", equipment: "dumbbell", target: "pectorals", secondary: ["triceps"]),
    ]
    private static let requirements = ExerciseRequirements(groups: ["bb": [["barbell"]], "db": [["dumbbells"]]])

    /// A gym with dumbbells and no barbell: normally `bb` would be swapped for `db` here.
    private var dumbbellGym: GymAdapter {
        let listing = InventoryListing(id: UUID(), kindId: "dumbbells")
        let matcher = InventoryMatcher(requirements: Self.requirements, kinds: Self.kinds,
                                       inventory: GymInventory(gymName: "Gym", listings: [listing]))
        return GymAdapter(matcher: matcher, exercises: Self.exercises)
    }

    private let item = RoutineExercise(exerciseId: "bb", sets: 3, reps: 10, repsMin: 8)

    @Test func isABuiltPlanNamedSharedWorkout() {
        let plan = TodayPlan.shared(items: [item], day: day)
        #expect(plan.kind == .built)
        #expect(plan.title == "Shared workout")
        #expect(plan.exercises == [item])
        #expect(plan.day == day)
        #expect(plan.routineToStart?.name == "Shared workout")
    }

    @Test func theGymCantSwapItsExercises() {
        let plan = TodayPlan.shared(items: [item], day: day).adapted(by: dumbbellGym)
        #expect(plan.exercises.map(\.exerciseId) == ["bb"])
        #expect(plan.gymSwaps.isEmpty)
    }

    @Test func aWithoutPinsControl() {
        let plan = TodayPlan.built(name: "Built", items: [item], day: day).adapted(by: dumbbellGym)
        #expect(plan.exercises.map(\.exerciseId) == ["db"])
    }

    @Test func survivesAReloadWithItsPins() throws {
        let plan = TodayPlan.shared(items: [item], day: day)
        let data = try JSONEncoder().encode(plan)
        let loaded = try JSONDecoder().decode(TodayPlan.self, from: data)
        #expect(loaded == plan)
        #expect(loaded.gymPinned == [item.id])
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
}
