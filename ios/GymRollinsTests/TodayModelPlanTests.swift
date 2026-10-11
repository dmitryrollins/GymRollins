import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Today's title and summary line for each kind of plan.
@Suite struct TodayModelPlanTests {
    private let library = ExerciseLibrary(exercises: [
        Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
        Exercise(id: "0027", name: "barbell bent over row", bodyPart: "back", equipment: "barbell", target: "upper back"),
    ])
    private let push = Routine(name: "Push", exercises: [RoutineExercise(exerciseId: "0025", sets: 3, reps: 8)])

    private func model(_ plan: TodayPlan) -> TodayModel {
        TodayModel.make(plan: plan, profile: Profile(), library: library, history: { _ in [] })
    }

    @Test func scheduledKeepsTheUsualSummary() {
        let m = model(TodayPlan.make(scheduled: push, routines: [push], lastDone: [:], day: "d"))
        #expect(m.title == "Push")
        #expect(m.summary == "1 exercise")
        #expect(m.routineId == push.id)
    }

    @Test func unplannedDayIsAnOptionalRestDay() {
        let m = model(TodayPlan.make(scheduled: nil, routines: [push], lastDone: [:], day: "d"))
        #expect(m.title == "Push")
        #expect(m.summary == "Rest day \u{00B7} optional \u{00B7} 1 exercise")
        #expect(m.rows.count == 1)
    }

    @Test func editedAndEmptyWorkouts() {
        let edited = TodayPlan.make(scheduled: push, routines: [push], lastDone: [:], day: "d")
            .adding([RoutineExercise(exerciseId: "0027", sets: 3, reps: 8)])
        #expect(model(edited).summary == "2 exercises \u{00B7} edited for today")

        let empty = TodayPlan.make(scheduled: push, routines: [push], lastDone: [:], day: "d").switched(to: nil)
        let e = model(empty)
        #expect(e.title == "Empty workout")
        #expect(e.summary == "Add exercises, or start and add them as you go")
        #expect(e.rows.isEmpty)
        #expect(model(empty.adding([RoutineExercise(exerciseId: "0027", sets: 3, reps: 8)])).rows.count == 1)
    }
}
