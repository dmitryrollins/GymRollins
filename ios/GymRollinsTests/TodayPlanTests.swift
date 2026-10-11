import Foundation
import GymCore
import Testing
@testable import GymRollins

/// Today's workout before it starts: the scheduled routine, or on an unplanned day the next routine in rotation;
/// Switch; replace / delete / add exercises for today only; save the edits back to the routine.
@Suite struct TodayPlanTests {
    private let day = "2026-09-29"
    private let now = ISO8601DateFormatter().date(from: "2026-09-29T09:00:00Z")!

    private func routine(_ name: String, _ ids: [String], paused: Bool = false) -> Routine {
        Routine(name: name, paused: paused, exercises: ids.map { RoutineExercise(exerciseId: $0, sets: 3, reps: 8) })
    }

    // MARK: Which workout

    @Test func scheduledRoutineIsToday() {
        let push = routine("Push", ["0025"])
        let plan = TodayPlan.make(scheduled: push, routines: [push], lastDone: [:], day: day)
        #expect(plan.kind == .scheduled)
        #expect(plan.title == "Push")
        #expect(plan.exercises.map(\.exerciseId) == ["0025"])
        #expect(!plan.edited)
    }

    @Test func unplannedDaySuggestsTheRoutineDoneLeastRecently() {
        let push = routine("Push", ["0025"]), pull = routine("Pull", ["0027"]), legs = routine("Legs", ["0043"])
        let lastDone: [UUID: Date] = [push.id: now.addingTimeInterval(-86_400), pull.id: now.addingTimeInterval(-5 * 86_400),
                                      legs.id: now.addingTimeInterval(-2 * 86_400)]
        let plan = TodayPlan.make(scheduled: nil, routines: [push, pull, legs], lastDone: lastDone, day: day)
        #expect(plan.kind == .restDaySuggestion)
        #expect(plan.base?.id == pull.id)
    }

    @Test func neverDoneRoutinesComeFirstInPlanOrder_pausedAndEmptyOnesAreSkipped() {
        let paused = routine("Paused", ["0001"], paused: true), empty = routine("Empty", [])
        let done = routine("Done", ["0025"]), fresh = routine("Fresh", ["0027"]), fresh2 = routine("Fresh2", ["0043"])
        let plan = TodayPlan.make(scheduled: nil, routines: [paused, empty, done, fresh, fresh2],
                                  lastDone: [done.id: now], day: day)
        #expect(plan.base?.name == "Fresh")
    }

    @Test func noUsableRoutineMeansAnEmptyWorkout() {
        let plan = TodayPlan.make(scheduled: nil, routines: [routine("Paused", ["0001"], paused: true)],
                                  lastDone: [:], day: day)
        #expect(plan.kind == .empty)
        #expect(plan.base == nil)
        #expect(plan.exercises.isEmpty)
        #expect(plan.title == "Empty workout")
        #expect(plan.routineToStart == nil)
    }

    @Test func switchPicksAnotherRoutineOrAnEmptyWorkoutForTodayOnly() {
        let push = routine("Push", ["0025"]), pull = routine("Pull", ["0027", "0029"])
        let plan = TodayPlan.make(scheduled: push, routines: [push, pull], lastDone: [:], day: day)
        let switched = plan.switched(to: pull)
        #expect(switched.kind == .switched)
        #expect(switched.base?.id == pull.id)
        #expect(switched.exercises.count == 2)
        #expect(!switched.edited)
        let empty = plan.switched(to: nil)
        #expect(empty.kind == .empty)
        #expect(empty.exercises.isEmpty)
    }

    // MARK: Edits (today only)

    @Test func replaceDeleteAndAddMarkThePlanEdited() throws {
        let push = routine("Push", ["0025", "0027"])
        let plan = TodayPlan.make(scheduled: push, routines: [push], lastDone: [:], day: day)
        let first = try #require(plan.exercises.first)

        let replaced = plan.replacing(first.id, with: RoutineExercise(exerciseId: "0030", sets: 4, reps: 10))
        #expect(replaced.exercises.map(\.exerciseId) == ["0030", "0027"])
        #expect(replaced.exercises.first?.sets == 4)
        #expect(replaced.edited)

        let deleted = replaced.deleting(replaced.exercises[1].id)
        #expect(deleted.exercises.map(\.exerciseId) == ["0030"])

        let added = deleted.adding([RoutineExercise(exerciseId: "0043", sets: 3, reps: 12)])
        #expect(added.exercises.map(\.exerciseId) == ["0030", "0043"])
        #expect(added.base?.exercises.map(\.exerciseId) == ["0025", "0027"], "the routine itself is untouched")
    }

    @Test func addingSkipsExercisesAlreadyInTheWorkout() {
        let push = routine("Push", ["0025"])
        let plan = TodayPlan.make(scheduled: push, routines: [push], lastDone: [:], day: day)
        let added = plan.adding([RoutineExercise(exerciseId: "0025", sets: 3, reps: 8),
                                 RoutineExercise(exerciseId: "0027", sets: 3, reps: 8)])
        #expect(added.exercises.map(\.exerciseId) == ["0025", "0027"])
    }

    @Test func routineToStartKeepsTheRoutineIdentityWithTheEditedExercises() throws {
        let push = routine("Push", ["0025"])
        let plan = TodayPlan.make(scheduled: push, routines: [push], lastDone: [:], day: day)
            .adding([RoutineExercise(exerciseId: "0027", sets: 3, reps: 8)])
        let start = try #require(plan.routineToStart)
        #expect(start.id == push.id)
        #expect(start.name == "Push")
        #expect(start.exercises.map(\.exerciseId) == ["0025", "0027"])

        let adHoc = plan.switched(to: nil).adding([RoutineExercise(exerciseId: "0043", sets: 3, reps: 8)])
        let adHocStart = try #require(adHoc.routineToStart)
        #expect(adHocStart.name == "Workout")
        #expect(adHocStart.exercises.count == 1)
    }

    @Test func savingToRoutineWritesTheEditsIntoTheRoutine() throws {
        let push = routine("Push", ["0025"])
        let plan = TodayPlan.make(scheduled: push, routines: [push], lastDone: [:], day: day)
            .adding([RoutineExercise(exerciseId: "0027", sets: 3, reps: 8)])
        let saved = try #require(plan.routineWithEdits(at: now))
        #expect(saved.id == push.id)
        #expect(saved.exercises.map(\.exerciseId) == ["0025", "0027"])
        #expect(plan.switched(to: nil).routineWithEdits(at: now) == nil, "an empty workout has no routine to save into")
        #expect(!plan.savedToRoutine(at: now).edited)
    }

    // MARK: Persistence (the edits survive a relaunch the same day)

    @Test func storedPlanIsReusedOnlyTheSameDayAndWhileItsRoutineExists() throws {
        let suite = "today-plan-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TodayPlanStore(defaults: defaults)
        let push = routine("Push", ["0025"]), pull = routine("Pull", ["0027"])
        let edited = TodayPlan.make(scheduled: push, routines: [push, pull], lastDone: [:], day: day).switched(to: pull)
        store.save(edited)

        #expect(store.load(day: day, routineIds: [push.id, pull.id]) == edited)
        #expect(store.load(day: "2026-09-30", routineIds: [push.id, pull.id]) == nil, "a new day starts fresh")
        #expect(store.load(day: day, routineIds: [push.id]) == nil, "its routine was deleted")
        store.clear()
        #expect(store.load(day: day, routineIds: [push.id, pull.id]) == nil)
    }

    @Test func untouchedScheduledPlanIsNotStored_soPlanEditsShowUp() throws {
        let suite = "today-plan-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TodayPlanStore(defaults: defaults)
        let push = routine("Push", ["0025"])
        store.save(TodayPlan.make(scheduled: push, routines: [push], lastDone: [:], day: day))
        #expect(store.load(day: day, routineIds: [push.id]) == nil)
    }
}
