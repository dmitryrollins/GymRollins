import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@MainActor
@Suite struct WorkoutGymLinkTests {
    private let library = ExerciseLibrary(exercises: [
        Exercise(id: "0313", name: "dumbbell hammer curl", bodyPart: "upper arms", equipment: "dumbbell", target: "biceps"),
        Exercise(id: "0251", name: "chest dip", bodyPart: "chest", equipment: "body weight", target: "pectorals"),
    ])

    @Test func plannerStoresTheGymAndTheListingEachExerciseWasFittedTo() {
        let gym = UUID(), listing = UUID()
        let routine = Routine(name: "Arms", exercises: [
            RoutineExercise(exerciseId: "0313", sets: 3, reps: 10, repsMin: 8),
            RoutineExercise(exerciseId: "0251", sets: 3, reps: 10),
        ])
        let workout = SessionPlanner.start(routine: routine, profile: Profile(), library: library, now: .now,
                                           history: { _ in [] }, gymId: gym,
                                           loadListing: { $0 == "0313" ? listing : nil })
        #expect(workout.gymId == gym)
        #expect(workout.entries.map(\.gymListingId) == [listing, nil])
    }

    @Test func plannerWithoutAGymStoresNothing() {
        let routine = Routine(name: "Arms", exercises: [RoutineExercise(exerciseId: "0313", sets: 3, reps: 10)])
        let workout = SessionPlanner.start(routine: routine, profile: Profile(), library: library, now: .now,
                                           history: { _ in [] })
        #expect(workout.gymId == nil && workout.entries.allSatisfy { $0.gymListingId == nil })
    }

    @Test func aWorkoutStartedAtTheCurrentGymStoresItAndTheListingTodayShowed() throws {
        let rig = try GymTestRig.make()
        let routine = Routine(name: "KB", exercises: [
            RoutineExercise(exerciseId: "0541", sets: 3, reps: 12, repsMin: 10, weightKg: 30),
        ])
        try rig.env.routines.upsert(routine)
        try rig.switchToday(to: routine)
        let gym = try rig.gym("Kettlebells", kettlebellGym)
        rig.env.setCurrentGym(gym.id)
        let bells = try #require(try rig.env.gyms.listings(gymId: gym.id).first { $0.item.kindId == "kettlebells" })

        #expect(rig.env.startTodaysWorkout())

        let workout = try #require(rig.env.session?.workout)
        #expect(workout.gymId == gym.id)
        #expect(workout.entries.first?.gymListingId == bells.id)
        let stored = try #require(try rig.env.workouts.active())
        #expect(stored.gymId == gym.id && stored.entries.first?.gymListingId == bells.id)
    }

    @Test func withNoCurrentGymBothLinksAreNil() throws {
        let rig = try GymTestRig.make()
        let routine = Routine(name: "KB", exercises: [RoutineExercise(exerciseId: "0541", sets: 3, reps: 12)])
        try rig.env.routines.upsert(routine)
        try rig.switchToday(to: routine)

        #expect(rig.env.startTodaysWorkout())

        let workout = try #require(rig.env.session?.workout)
        #expect(workout.gymId == nil && workout.entries.allSatisfy { $0.gymListingId == nil })
    }

    @Test func aDeletedGymLeavesTheActiveWorkoutAndItsExerciseShowing() throws {
        let rig = try GymTestRig.make()
        let routine = Routine(name: "KB", exercises: [RoutineExercise(exerciseId: "0541", sets: 3, reps: 12)])
        try rig.env.routines.upsert(routine)
        try rig.switchToday(to: routine)
        let gym = try rig.gym("Kettlebells", kettlebellGym)
        rig.env.setCurrentGym(gym.id)
        #expect(rig.env.startTodaysWorkout())

        try rig.env.deleteGym(gym.id)

        let workout = try #require(rig.env.session?.workout)
        #expect(workout.entries.map(\.exerciseId) == ["0541"] && workout.gymId == gym.id)
        #expect(try rig.env.workouts.active()?.entries.count == 1)
    }
}
