import Foundation
import GymCore
import Testing
@testable import GymRollins

/// The plan-mode exercise screen edits today's plan through `TodayPlanEditor` (and `ExerciseScreenModel.plan`): the
/// same today-only edits the inline editor made, saved for the day, and Start Workout lands on that exercise.
@MainActor
@Suite struct TodayPlanEditorTests {
    private let day = "2026-09-29"
    private let lb = { (v: Double) in UnitConverter.toKg(v, from: .lb) }
    private let bench = RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, repsMin: 8)
    private let row = RoutineExercise(exerciseId: "0027", sets: 3, reps: 8)
    private let routine: Routine

    init() { routine = Routine(name: "Push", exercises: [bench, row]) }

    /// Two warm-ups and three working sets at 135 lb, fresh ids on every call (like `SessionPlanner.entry`).
    private func suggested(_ item: RoutineExercise, _: TodayPlan) -> [WorkoutSet] {
        [WorkoutSet(weightKg: lb(45), reps: 10, warmup: true), WorkoutSet(weightKg: lb(95), reps: 5, warmup: true)]
            + (0..<item.sets).map { _ in WorkoutSet(weightKg: lb(135), reps: 8) }
    }

    private func editor(_ defaults: UserDefaults? = nil) -> TodayPlanEditor {
        let editor = TodayPlanEditor(store: defaults.map { TodayPlanStore(defaults: $0) }, defaultRestSec: 90,
                                     suggest: suggested)
        editor.load(TodayPlan.make(scheduled: routine, routines: [routine], lastDone: [:], day: day))
        return editor
    }

    private func freshDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "TodayPlanEditorTests.\(UUID())"))
    }

    @Test func suggestedSetsKeepTheirIdsUntilEdited() {
        let editor = editor()
        let first = editor.sets(for: bench.id)
        #expect(first.count == 5)
        #expect(editor.sets(for: bench.id) == first, "typing into a box needs stable set ids")
        #expect(!editor.isEdited(bench.id))
    }

    @Test func aReloadKeepsTheSuggestedSetIdsSoPendingTypingStillApplies() {
        let editor = editor()
        let before = editor.sets(for: bench.id)
        editor.load(TodayPlan.make(scheduled: routine, routines: [routine], lastDone: [:], day: day))
        #expect(editor.sets(for: bench.id).map(\.id) == before.map(\.id))
        editor.invalidateSuggestions()
        #expect(editor.sets(for: bench.id).map(\.id) == before.map(\.id), "history changed: same rows, fresh values")
        editor.updateSet(bench.id, setId: before[3].id) { $0.with(weightKg: lb(150), reps: 7) }
        #expect(editor.isEdited(bench.id))
    }

    @Test func idsAreNotReusedWhenTheSetStructureOrDayChanges() {
        var warmups = 2
        let editor = TodayPlanEditor(store: nil, defaultRestSec: 90) { _, _ in
            (0..<warmups).map { _ in WorkoutSet(weightKg: 20, reps: 10, warmup: true) }
                + [WorkoutSet(weightKg: 60, reps: 8), WorkoutSet(weightKg: 60, reps: 8)]
        }
        editor.load(TodayPlan.make(scheduled: routine, routines: [routine], lastDone: [:], day: day))
        let before = Set(editor.sets(for: bench.id).map(\.id))
        warmups = 1
        editor.invalidateSuggestions()
        #expect(before.isDisjoint(with: editor.sets(for: bench.id).map(\.id)), "a draft never lands on another set")

        let today = editor.sets(for: bench.id).map(\.id)
        editor.load(TodayPlan.make(scheduled: routine, routines: [routine], lastDone: [:], day: "2026-09-30"))
        #expect(Set(today).isDisjoint(with: editor.sets(for: bench.id).map(\.id)), "yesterday's typing stays there")
    }

    @Test func aLockedEditorChangesNothing() throws {
        let defaults = try freshDefaults()
        let editor = editor(defaults)
        editor.isLocked = true // a workout started (e.g. from the watch)
        editor.updateSet(bench.id, setId: editor.sets(for: bench.id)[3].id) { $0.with(weightKg: lb(150), reps: 7) }
        editor.setRest(150)
        #expect(!editor.isEdited(bench.id))
        #expect(editor.plan?.restSec == nil)
        #expect(TodayPlanStore(defaults: defaults).load(day: day, routineIds: [routine.id]) == nil)
    }

    @Test func planRestOffersTheWholeSupportedRange() {
        let options = RestSettingsSheet.options(in: DomainLimits.restSec, including: 95)
        #expect(options.first == 0)
        #expect(options.last == 900)
        #expect(options.contains(95), "a stored value off the 15 s grid still has a row")
        #expect(RestSettingsSheet.options(in: 30...300, including: 90).count == 19)
    }

    @Test func editingSetTwoChangesOnlyThatSetAndIsSaved() throws {
        let defaults = try freshDefaults()
        let editor = editor(defaults)
        let setTwo = editor.sets(for: bench.id)[3]
        editor.updateSet(bench.id, setId: setTwo.id) { $0.with(weightKg: lb(150), reps: 7) }
        let sets = editor.sets(for: bench.id)
        #expect(sets[3].weightKg == lb(150))
        #expect(sets[3].reps == 7)
        #expect(sets[3].id == setTwo.id)
        #expect(sets[2].weightKg == lb(135))
        #expect(editor.isEdited(bench.id))
        #expect(editor.plan?.canSaveToRoutine == true)
        let stored = TodayPlanStore(defaults: defaults).load(day: day, routineIds: [routine.id])
        #expect(stored?.sets(for: bench.id)?[3].weightKg == lb(150), "edits survive a relaunch the same day")
    }

    @Test func unchangedUpdateDoesNotMarkEdited() {
        let editor = editor()
        let set = editor.sets(for: bench.id)[2]
        editor.updateSet(bench.id, setId: set.id) { $0 }
        #expect(!editor.isEdited(bench.id))
    }

    @Test func addRemoveAndWarmupToggle() {
        let editor = editor()
        editor.addSet(bench.id)
        #expect(editor.sets(for: bench.id).count == 6)
        let warmup = editor.sets(for: bench.id)[0]
        #expect(editor.canRemoveSet(bench.id, setId: warmup.id))
        editor.removeSet(bench.id, setId: warmup.id)
        #expect(editor.sets(for: bench.id).count == 5)
        let working = editor.sets(for: bench.id)[1]
        editor.toggleWarmup(bench.id, setId: working.id)
        #expect(editor.sets(for: bench.id)[1].warmup)
        #expect(editor.sets(for: bench.id)[1].id == working.id)
    }

    @Test func theLastWorkingSetCannotBeRemoved() {
        let single = RoutineExercise(exerciseId: "0001", sets: 1, reps: 10)
        let solo = Routine(name: "Solo", exercises: [single])
        let editor = TodayPlanEditor(store: nil, defaultRestSec: 90) { _, _ in [WorkoutSet(weightKg: 20, reps: 10)] }
        editor.load(TodayPlan.make(scheduled: solo, routines: [solo], lastDone: [:], day: day))
        let only = editor.sets(for: single.id)[0]
        #expect(!editor.canRemoveSet(single.id, setId: only.id))
        editor.removeSet(single.id, setId: only.id)
        #expect(editor.sets(for: single.id).count == 1)
    }

    @Test func restIsTodayOnlyAndTheDefaultMeansNone() {
        let editor = editor()
        #expect(editor.restSec == 90)
        editor.setRest(150)
        #expect(editor.restSec == 150)
        #expect(editor.plan?.restSec == 150)
        #expect(editor.plan?.canSaveToRoutine == false, "rest isn't saved into the routine")
        editor.setRest(90)
        #expect(editor.plan?.restSec == nil)
    }

    @Test func resetGoesBackToAFreshSuggestion() {
        let editor = editor()
        let set = editor.sets(for: bench.id)[3]
        editor.updateSet(bench.id, setId: set.id) { $0.with(weightKg: lb(150), reps: 7) }
        editor.resetSets(bench.id)
        #expect(!editor.isEdited(bench.id))
        #expect(editor.sets(for: bench.id)[3].weightKg == lb(135))
    }

    @Test func replaceKeepsTheItemAndDropsItsSetEdits() {
        let editor = editor()
        let set = editor.sets(for: bench.id)[3]
        editor.updateSet(bench.id, setId: set.id) { $0.with(weightKg: lb(150), reps: 7) }
        editor.replace(bench.id, with: RoutineExercise(exerciseId: "0289", sets: 4, reps: 12))
        let item = editor.item(bench.id)
        #expect(item?.exerciseId == "0289", "the screen stays on the same item, now another exercise")
        #expect(item?.sets == 4)
        #expect(!editor.isEdited(bench.id))
        #expect(editor.sets(for: bench.id).count == 6, "the new exercise's own suggestion")
        #expect(editor.plan?.edited == true)
    }

    @Test func replaceNeverDuplicatesAnExerciseAlreadyInThePlan() {
        let editor = editor()
        editor.replace(bench.id, with: RoutineExercise(exerciseId: row.exerciseId, sets: 3, reps: 8))
        #expect(editor.item(bench.id)?.exerciseId == "0025")
        #expect(editor.plan?.edited == false)
        #expect(ExerciseScreenModel.plan(editor, itemId: bench.id).swapExcluded == ["0027"])
    }

    @Test func deleteRemovesTheItem() {
        let editor = editor()
        editor.delete(bench.id)
        #expect(editor.item(bench.id) == nil)
        #expect(editor.plan?.exercises.map(\.id) == [row.id])
    }

    @Test func screenModelMapsEditsToTodaysPlan() throws {
        let editor = editor()
        let model = ExerciseScreenModel.plan(editor, itemId: bench.id)
        #expect(model.isPlan)
        #expect(model.exerciseId == "0025")
        #expect(model.restSeconds == 90)
        let setTwo = model.sets?[3]
        model.updateSet(try #require(setTwo).id) { $0.with(weightKg: lb(150), reps: 7) }
        #expect(editor.plan?.sets(for: bench.id)?[3].reps == 7)
        model.addSet()
        #expect(model.sets?.count == 6)
        model.setRestSeconds(120)
        #expect(editor.plan?.restSec == 120)
        #expect(model.isEdited)
        #expect(ExerciseScreenModel.plan(editor, itemId: UUID()).sets == nil, "a deleted item closes the screen")
    }

    @Test func startingFromAnExerciseSelectsItsEntry() {
        let plan = TodayPlan.make(scheduled: routine, routines: [routine], lastDone: [:], day: day)
        let workout = Workout(startedAt: .now, routineId: routine.id, name: "Push", entries: [
            WorkoutEntry(exerciseId: "0025", sets: []), WorkoutEntry(exerciseId: "0027", sets: [])
        ])
        #expect(plan.entryId(for: row.id, in: workout) == workout.entries[1].id)
        #expect(plan.entryId(for: bench.id, in: workout) == workout.entries[0].id)
        #expect(plan.entryId(for: UUID(), in: workout) == nil)
        let mismatched = Workout(startedAt: .now, name: "Other", entries: [WorkoutEntry(exerciseId: "0100", sets: [])])
        #expect(plan.entryId(for: bench.id, in: mismatched) == nil, "never opens another exercise")
    }
}
