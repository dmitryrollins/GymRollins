import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Today's sets edited for today (on the plan-mode exercise screen): they live in today's plan (persisted for the day), start the
/// workout with exactly those values, and "Save Changes to <routine>" writes sets/reps/weight into the routine.
@Suite struct TodayPlanSetEditTests {
    private let day = "2026-09-29"
    private let now = ISO8601DateFormatter().date(from: "2026-09-29T09:00:00Z")!
    private let lb = { (v: Double) in UnitConverter.toKg(v, from: .lb) }

    private func plan() -> (TodayPlan, RoutineExercise) {
        let bench = RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, repsMin: 8, weightKg: lb(135))
        let row = RoutineExercise(exerciseId: "0027", sets: 3, reps: 8)
        let push = Routine(name: "Push", exercises: [bench, row])
        return (TodayPlan.make(scheduled: push, routines: [push], lastDone: [:], day: day), bench)
    }

    private func sets(_ weights: [Double], reps: Int = 10, warmups: Int = 0) -> [WorkoutSet] {
        weights.enumerated().map { i, w in WorkoutSet(weightKg: lb(w), reps: reps, warmup: i < warmups) }
    }

    // MARK: Pure set edits

    @Test func editsChangeOneSetAndKeepTheRest() {
        let base = sets([45, 135, 135, 135], warmups: 1)
        let edited = TodaySetEdits.replacing(base, index: 2, with: base[2].with(weightKg: lb(140), reps: 9))
        #expect(edited[2].weightKg == lb(140))
        #expect(edited[2].reps == 9)
        #expect(edited[2].id == base[2].id)
        #expect(Array(edited[0...1]) == Array(base[0...1]))
        #expect(edited[3] == base[3])
    }

    @Test func addingASetCopiesTheLastWorkingSet() {
        let added = TodaySetEdits.adding(to: sets([45, 135, 140], warmups: 1))
        #expect(added.count == 4)
        #expect(added[3].weightKg == lb(140))
        #expect(!added[3].warmup)
        #expect(added[3].id != added[2].id)
        let fromWarmupsOnly = TodaySetEdits.adding(to: sets([45], warmups: 1))
        #expect(fromWarmupsOnly.last?.warmup == false)
    }

    @Test func removingKeepsAtLeastOneWorkingSet() {
        let base = sets([45, 135], warmups: 1)
        #expect(TodaySetEdits.removing(from: base, index: 0).count == 1)
        #expect(TodaySetEdits.removing(from: base, index: 1) == base, "the only working set stays")
        #expect(TodaySetEdits.removing(from: sets([135, 135]), index: 5).count == 2, "out of range is ignored")
    }

    @Test func warmupToggleKeepsAtLeastOneWorkingSet() {
        let base = sets([45, 135, 135], warmups: 1)
        #expect(TodaySetEdits.togglingWarmup(base, index: 1)[1].warmup)
        #expect(!TodaySetEdits.togglingWarmup(base, index: 0)[0].warmup)
        let one = sets([135])
        #expect(TodaySetEdits.togglingWarmup(one, index: 0) == one)
    }

    @Test func savingAlwaysPlansTheShownLoad() throws {
        let (plan, bench) = plan()
        // Same weight as the routine's (135), e.g. going back to it while progression suggests more.
        let saved = try #require(plan.editingSets(bench.id, sets([135, 135, 135])).routineWithEdits(at: now))
        #expect(saved.exercises[0].weightKg == lb(135))
        #expect(saved.exercises[0].weightSetAt == now, "an explicit load wins over progression next time")
    }

    @Test func savingAZeroLoadKeepsItExplicit() throws {
        let dips = RoutineExercise(exerciseId: "0251", sets: 3, reps: 10) // no planned weight, history may have some
        let routine = Routine(name: "Push", exercises: [dips])
        let plan = TodayPlan.make(scheduled: routine, routines: [routine], lastDone: [:], day: day)
        let saved = try #require(plan.editingSets(dips.id, sets([0, 0, 0])).routineWithEdits(at: now))
        #expect(saved.exercises[0].weightKg == 0)
        #expect(saved.exercises[0].weightSetAt == now, "bodyweight is the plan now, not the historical load")
    }

    @Test func workingSetsAreCappedLikeTheRoutine() {
        let ten = sets(Array(repeating: 135, count: 10))
        #expect(TodaySetEdits.adding(to: ten) == ten)
    }

    // MARK: In the plan

    @Test func setEditsMarkThePlanEditedAndAreKeptPerExercise() throws {
        let (plan, bench) = plan()
        #expect(plan.sets(for: bench.id) == nil, "untouched rows follow the suggestion")
        let edited = plan.editingSets(bench.id, sets([140, 140, 140]))
        #expect(edited.sets(for: bench.id)?.map(\.weightKg) == [lb(140), lb(140), lb(140)])
        #expect(edited.edited)
        #expect(edited.hasSetEdits(bench.id))
        let reset = edited.resettingSets(bench.id)
        #expect(reset.sets(for: bench.id) == nil)
        #expect(!reset.edited, "back to the routine as scheduled")
    }

    @Test func deletingOrReplacingAnExerciseDropsItsSetEdits() throws {
        let (plan, bench) = plan()
        let edited = plan.editingSets(bench.id, sets([140]))
        #expect(edited.deleting(bench.id).sets(for: bench.id) == nil)
        #expect(edited.replacing(bench.id, with: RoutineExercise(exerciseId: "0030", sets: 3, reps: 8))
            .sets(for: bench.id) == nil)
    }

    @Test func todaysRestIsATodayOnlyEdit() {
        let (plan, _) = plan()
        let rested = plan.withRest(150)
        #expect(rested.restSec == 150)
        #expect(rested.hasTodayChanges, "kept for today")
        #expect(!rested.edited, "nothing to save into the routine (routines have no rest)")
        #expect(!rested.withRest(nil).hasTodayChanges)
    }

    @Test func savingToTheRoutineWritesSetsRepsAndWorkingWeight() throws {
        let (plan, bench) = plan()
        let edited = plan.editingSets(bench.id, sets([45, 140, 140, 140, 140], reps: 9, warmups: 1))
        let saved = try #require(edited.routineWithEdits(at: now))
        let item = try #require(saved.exercises.first)
        #expect(item.id == bench.id)
        #expect(item.sets == 4, "working sets only; warm-ups are generated")
        #expect(item.reps == 10, "9 is inside 8–10: the range stays")
        #expect(item.repsMin == 8)
        #expect(item.weightKg == lb(140))
        #expect(item.weightSetAt == now, "the planned weight overrides progression next time")
        #expect(saved.exercises[1] == plan.exercises[1], "untouched exercises are unchanged")
    }

    @Test func repsAboveTheRangeRaiseItsTop() throws {
        let (plan, bench) = plan()
        let saved = try #require(plan.editingSets(bench.id, sets([135, 135], reps: 12)).routineWithEdits(at: now))
        #expect(saved.exercises[0].reps == 12)
        #expect(saved.exercises[0].repsMin == 8)
    }

    @Test func savingKeepsTheRepRangeValid() throws {
        let (plan, bench) = plan()
        let saved = try #require(plan.editingSets(bench.id, sets([135, 135], reps: 6)).routineWithEdits(at: now))
        #expect(saved.exercises[0].reps == 6)
        #expect(saved.exercises[0].repsMin == nil, "a range bottom above the new top is dropped")
    }

    @Test func savedPlanStillStartsWithTodaysSets() throws {
        let (plan, bench) = plan()
        let edited = plan.editingSets(bench.id, sets([140, 140]))
        let saved = edited.savedToRoutine(at: now)
        #expect(!saved.edited)
        #expect(saved.sets(for: bench.id) == edited.sets(for: bench.id))
        #expect(saved.routineWithEdits(at: now) == nil)
    }

    @Test func setEditsSurviveARelaunchTheSameDayOnly() throws {
        let suite = "today-sets-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TodayPlanStore(defaults: defaults)
        let (plan, bench) = plan()
        let edited = plan.editingSets(bench.id, sets([140])).withRest(90)
        store.save(edited)
        let ids = Set([try #require(edited.base?.id)])
        #expect(store.load(day: day, routineIds: ids) == edited)
        #expect(store.load(day: "2026-09-30", routineIds: ids) == nil, "the next day starts fresh")
        store.save(edited.savedToRoutine(at: now))
        #expect(store.load(day: day, routineIds: ids)?.sets(for: bench.id) != nil, "saved plans keep today's sets")
    }

    @Test func aSavedPlanFollowsLaterRoutineChanges() throws {
        let suite = "today-sets-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TodayPlanStore(defaults: defaults)
        let (plan, bench) = plan()
        let saved = plan.editingSets(bench.id, sets([140, 140])).savedToRoutine(at: now)
        store.save(saved)
        // Later, My Plan changes the other exercise (and drops nothing we edited).
        let base = try #require(saved.base)
        let row = base.exercises[1]
        let changedRow = RoutineExercise(id: row.id, exerciseId: row.exerciseId, sets: 5, reps: 5)
        let current = base.with(exercises: [base.exercises[0], changedRow])
        let loaded = try #require(store.load(day: day, routines: [current], scheduled: current.id))
        #expect(loaded.base == current, "the stored snapshot is rebased on the current routine")
        #expect(loaded.exercises == current.exercises)
        #expect(loaded.sets(for: bench.id) == saved.sets(for: bench.id), "today's sets stay")
        #expect(loaded.routineWithEdits(at: now) == nil, "nothing stale left to save back")

        // Claude swapped the edited exercise (same item id, another exercise): its sets don't carry over.
        let swapped = RoutineExercise(id: bench.id, exerciseId: "0289", sets: 3, reps: 10)
        let afterSwap = try #require(store.load(day: day, routines: [base.with(exercises: [swapped, changedRow])],
                                                scheduled: base.id))
        #expect(afterSwap.sets(for: bench.id) == nil)

        // The edited exercise was removed from the routine meanwhile: its sets go too.
        let without = base.with(exercises: [changedRow])
        let pruned = try #require(store.load(day: day, routines: [without], scheduled: base.id))
        #expect(pruned.sets(for: bench.id) == nil)
        #expect(pruned.exercises == [changedRow])
    }

    @Test func aLaterSaveDoesNotRewriteSetsSavedBefore() throws {
        let (plan, bench) = plan()
        let row = plan.exercises[1]
        let saved = plan.editingSets(bench.id, sets([150, 150, 150])).savedToRoutine(at: now)
        // My Plan then moves bench to 160 lb; Today rebases on it (keeping today's saved sets for bench).
        let base = try #require(saved.base)
        let newerBench = RoutineExercise(id: bench.id, exerciseId: bench.exerciseId, sets: 3, reps: 10, repsMin: 8,
                                         weightKg: lb(160))
        let rebased = saved.rebased(on: base.with(exercises: [newerBench, row]))
        #expect(!rebased.edited)
        // Editing and saving another exercise leaves bench at 160 lb.
        let other = rebased.editingSets(row.id, sets([100, 100, 100], reps: 8))
        let routine = try #require(other.routineWithEdits(at: now))
        #expect(routine.exercises[0] == newerBench)
        #expect(routine.exercises[1].weightKg == lb(100))
        #expect(other.sets(for: bench.id) != nil, "bench still starts today with today's sets")
    }

    @Test func aStoredPlanGivesWayToAScheduleChange() throws {
        let suite = "today-sets-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TodayPlanStore(defaults: defaults)
        let (plan, bench) = plan()
        let base = try #require(plan.base)
        let legs = Routine(name: "Legs", exercises: [RoutineExercise(exerciseId: "0043", sets: 3, reps: 5)])
        store.save(plan.editingSets(bench.id, sets([140])))
        #expect(store.load(day: day, routines: [base, legs], scheduled: base.id) != nil)
        #expect(store.load(day: day, routines: [base, legs], scheduled: legs.id) == nil, "today is Legs now")

        let restDay = TodayPlan.make(scheduled: nil, routines: [base], lastDone: [:], day: day).withRest(90)
        store.save(restDay)
        #expect(store.load(day: day, routines: [base, legs], scheduled: nil) != nil)
        #expect(store.load(day: day, routines: [base, legs], scheduled: legs.id) == nil, "no longer a rest day")

        store.save(plan.switched(to: legs))
        #expect(store.load(day: day, routines: [base, legs], scheduled: base.id)?.base?.id == legs.id,
                "a switch is the owner's choice and stays")
    }

    @Test func olderStoredPlansWithoutSetEditsStillDecode() throws {
        let json = #"{"day":"2026-09-29","kind":"empty","exercises":[],"edited":false}"#
        let decoded = try JSONDecoder().decode(TodayPlan.self, from: Data(json.utf8))
        #expect(decoded.setOverrides.isEmpty)
        #expect(decoded.restSec == nil)
    }

    // MARK: Starting the workout

    @Test func startingUsesTheEditedSetsAndRest() throws {
        let (plan, bench) = plan()
        let edited = plan.editingSets(bench.id, sets([45, 140, 140], reps: 9, warmups: 1)).withRest(150)
        let library = ExerciseLibrary(exercises: [
            Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
            Exercise(id: "0027", name: "barbell bent over row", bodyPart: "back", equipment: "barbell", target: "upper back"),
        ])
        let routine = try #require(edited.routineToStart)
        let workout = SessionPlanner.start(routine: routine, profile: Profile(), library: library, now: now,
                                           history: { _ in [] }, setOverrides: edited.setOverrides)
        let entry = try #require(workout.entries.first)
        #expect(entry.sets.map(\.weightKg) == [lb(45), lb(140), lb(140)])
        #expect(entry.sets.map(\.reps) == [9, 9, 9])
        #expect(entry.sets.map(\.warmup) == [true, false, false])
        #expect(entry.sets.allSatisfy { !$0.done })
        #expect(workout.entries[1].sets.filter { !$0.warmup }.count == 3, "untouched exercises use the suggestion")
    }
}
