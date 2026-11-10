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

    /// Logs the entry's auto warm-ups, then one working set, so a "done set" in these tests is real history.
    private func logAWorkingSet(_ session: WorkoutSession, _ entryId: UUID, weightKg: Double, reps: Int) {
        while let next = session.entry(entryId)?.sets.first(where: { !$0.done }), next.warmup {
            session.logNextSet(entryId: entryId, weightKg: next.weightKg, reps: next.reps)
        }
        session.logNextSet(entryId: entryId, weightKg: weightKg, reps: reps)
    }

    private func kettlebellExercise(_ rig: GymTestRig) throws -> Exercise {
        try #require(rig.env.library.exercises.first { $0.equipment == "kettlebell" && $0.mode == .reps })
    }

    @Test func aNeverLoggedExerciseKeepsNoImpossibleWeight() throws {
        let rig = try GymTestRig.make()
        let (session, entryId) = try startedSession(rig)
        logAWorkingSet(session, entryId, weightKg: 60, reps: 8)
        rig.env.setCurrentGym(try rig.gym("KB", kettlebellGym).id)
        let curl = try kettlebellExercise(rig)
        #expect(rig.env.gymLoads(curl.id) == kettlebells)

        ExerciseScreenModel.workout(session, entryId: entryId)
            .swap(to: curl, profile: rig.env.profile, history: [], loads: rig.env.gymLoads(curl.id))

        let sets = try #require(session.entry(entryId)?.sets)
        let doneWorking = sets.filter { $0.done && !$0.warmup }
        #expect(doneWorking.count == 1)
        #expect(doneWorking.allSatisfy { $0.weightKg == 60 && $0.reps == 8 }, "a done working set is history")
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
