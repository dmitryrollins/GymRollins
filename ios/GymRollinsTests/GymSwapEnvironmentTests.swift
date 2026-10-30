import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Swapping mid-workout at a gym: the undone sets must end on weights the gym has.
@MainActor
@Suite struct GymSwapEnvironmentTests {
    private func startedSession(_ rig: GymTestRig) throws -> (WorkoutSession, UUID) {
        let routine = Routine(name: "Row", exercises: [RoutineExercise(exerciseId: "0025", sets: 3, reps: 8, weightKg: 60)])
        try rig.env.routines.upsert(routine)
        rig.env.startSession(routine: routine)
        let session = try #require(rig.env.session)
        return (session, try #require(session.workout.entries.first?.id))
    }

    private func kettlebellExercise(_ rig: GymTestRig) throws -> Exercise {
        try #require(rig.env.library.exercises.first { $0.equipment == "kettlebell" && $0.mode == .reps })
    }

    @Test func aNeverLoggedExerciseKeepsNoImpossibleWeight() throws {
        let rig = try GymTestRig.make()
        let (session, entryId) = try startedSession(rig)
        session.logNextSet(entryId: entryId, weightKg: 60, reps: 8)
        rig.env.setCurrentGym(try rig.gym("KB", kettlebellGym).id)
        let curl = try kettlebellExercise(rig)
        #expect(rig.env.gymLoads(curl.id) == kettlebells)

        ExerciseScreenModel.workout(session, entryId: entryId)
            .swap(to: curl, profile: rig.env.profile, history: [], loads: rig.env.gymLoads(curl.id))

        let sets = try #require(session.entry(entryId)?.sets)
        let done = sets.filter(\.done)
        #expect(done.count == 1)
        #expect(done.allSatisfy { $0.weightKg == 60 }, "a done set is history")
        let undone = sets.filter { !$0.done && !$0.warmup }
        #expect(!undone.isEmpty)
        #expect(undone.allSatisfy { $0.weightKg == 24 }, "60 kg isn't a bell; the heaviest is 24")
        #expect(undone.allSatisfy { $0.reps == 8 }, "no history, so no extra reps")
    }

    @Test func aLoggedExerciseGetsItsSuggestionAndTheExtraReps() throws {
        let rig = try GymTestRig.make()
        let (session, entryId) = try startedSession(rig)
        rig.env.setCurrentGym(try rig.gym("KB", kettlebellGym).id)
        let curl = try kettlebellExercise(rig)
        let history = [SessionResult(date: rig.env.now(), weightKg: 30, reps: [10, 10, 10])]
        let item = RoutineDefaults.item(for: curl, profile: rig.env.profile)
        let plain = SessionPlanner.suggestion(for: item, policy: item.policy ?? .double, profile: rig.env.profile,
                                              exercise: curl, history: history)

        ExerciseScreenModel.workout(session, entryId: entryId)
            .swap(to: curl, profile: rig.env.profile, history: history, loads: rig.env.gymLoads(curl.id))

        let undone = try #require(session.entry(entryId)?.sets).filter { !$0.done && !$0.warmup }
        #expect(undone.allSatisfy { $0.weightKg == 24 })
        #expect(undone.allSatisfy { $0.reps == plain.reps + 2 }, "past the heaviest bell the rep target rises")
    }
}
