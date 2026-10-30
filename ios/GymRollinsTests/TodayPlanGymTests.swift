import Foundation
import GymCore
import Testing
@testable import GymRollins

/// A gym swap changes what today's session does, never what the plan says: it must not reach a saved routine, must
/// come back after a reload, and must not lose the sets typed on a swapped exercise.
@Suite struct TodayPlanGymTests {
    private let day = "2026-10-30"
    private let now = ISO8601DateFormatter().date(from: "2026-10-30T09:00:00Z")!

    // MARK: Fixtures

    private static let kinds = ["barbell", "dumbbells", "kettlebells", "cable-station"].map {
        EquipmentKind(id: $0, name: $0, category: .freeWeight, load: .none)
    }
    private static let exercises = [
        press("bb", "barbell"), press("db", "dumbbell"), press("kb", "kettlebell"), press("cable", "cable"),
        Exercise(id: "free", name: "Free", bodyPart: "back", equipment: "body weight", target: "lats"),
    ]
    private static let requirements = ExerciseRequirements(groups: [
        "bb": [["barbell"]], "db": [["dumbbells"]], "kb": [["kettlebells"]], "cable": [["cable-station"]],
    ])

    private static func press(_ id: String, _ equipment: String) -> Exercise {
        Exercise(id: id, name: id, bodyPart: "chest", equipment: equipment, target: "pectorals", secondary: ["triceps"])
    }

    /// A gym with just these kinds of equipment.
    private func adapter(_ kindIds: String...) -> GymAdapter {
        let listings = kindIds.enumerated().map { index, kind in
            InventoryListing(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                             kindId: kind)
        }
        let matcher = InventoryMatcher(requirements: Self.requirements, kinds: Self.kinds,
                                       inventory: GymInventory(gymName: "Gym", listings: listings))
        return GymAdapter(matcher: matcher, exercises: Self.exercises)
    }

    private var dumbbellGym: GymAdapter { adapter("dumbbells") }
    private var kettlebellGym: GymAdapter { adapter("kettlebells") }
    private var fullGym: GymAdapter { adapter("barbell", "dumbbells", "kettlebells", "cable-station") }

    private let routine = Routine(name: "Push", exercises: [
        RoutineExercise(exerciseId: "bb", sets: 3, reps: 8, weightKg: 60),
        RoutineExercise(exerciseId: "free", sets: 3, reps: 10),
    ])

    private func scheduled() -> TodayPlan {
        TodayPlan.make(scheduled: routine, routines: [routine], lastDone: [:], day: day)
    }

    private let typed = [WorkoutSet(weightKg: 30, reps: 12)]

    private var benchId: UUID { routine.exercises[0].id }
    private var freeId: UUID { routine.exercises[1].id }

    private func store() throws -> (TodayPlanStore, () -> Void) {
        let suite = "today-plan-gym-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (TodayPlanStore(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    // MARK: A swap is not an edit

    @Test func adaptedSwapsWithoutMarkingEdited() {
        let plan = scheduled().adapted(by: dumbbellGym)
        #expect(plan.exercises.map(\.exerciseId) == ["db", "free"])
        #expect(!plan.edited)
        #expect(!plan.canSaveToRoutine)
        #expect(!plan.hasTodayChanges)
        #expect(plan.plannedExercises == routine.exercises)
        #expect(plan.gymSwaps[benchId]?.exerciseId == "bb")
        #expect(plan.exercisesMatchBase)
    }

    @Test func routineToStartUsesTheSwap() throws {
        let plan = scheduled().adapted(by: dumbbellGym)
        let start = try #require(plan.routineToStart)
        #expect(start.id == routine.id)
        #expect(start.exercises.map(\.exerciseId) == ["db", "free"])
        #expect(start.exercises[0].id == benchId)
        let workout = Workout(startedAt: now, routineId: start.id, name: start.name,
                              entries: start.exercises.map { WorkoutEntry(exerciseId: $0.exerciseId, sets: []) })
        #expect(plan.entryId(for: benchId, in: workout) == workout.entries[0].id)
    }

    @Test func adaptedIsIdempotent() {
        let once = scheduled().adapted(by: dumbbellGym)
        #expect(once.adapted(by: dumbbellGym) == once)
    }

    @Test func adaptedWithNoGymUndoesEverySwap() {
        let plan = scheduled().adapted(by: dumbbellGym).adapted(by: nil)
        #expect(plan == scheduled())
    }

    @Test func changingGymsReDecides() {
        let atA = scheduled().adapted(by: dumbbellGym)
        #expect(atA.exercises[0].exerciseId == "db")
        let atB = atA.adapted(by: fullGym)
        #expect(atB.exercises[0].exerciseId == "bb")
        #expect(atB.gymSwaps.isEmpty)
        let atC = atB.adapted(by: kettlebellGym)
        #expect(atC.exercises[0].exerciseId == "kb")
        #expect(atC.gymSwaps[benchId]?.exerciseId == "bb")
    }

    // MARK: Saving

    @Test func saveChangesNeverWritesASwap() throws {
        let plan = scheduled().adapted(by: dumbbellGym)
            .adding([RoutineExercise(exerciseId: "cable", sets: 3, reps: 12)])
        #expect(plan.canSaveToRoutine)
        let saved = try #require(plan.routineWithEdits(at: now))
        #expect(saved.exercises.map(\.exerciseId) == ["bb", "free", "cable"])
        #expect(saved.exercises[0] == routine.exercises[0], "sets and weight of the planned exercise are untouched")
    }

    @Test func savedToRoutineKeepsTheSwapShowing() throws {
        let plan = scheduled().adapted(by: dumbbellGym)
            .adding([RoutineExercise(exerciseId: "cable", sets: 3, reps: 12)])
        let after = plan.savedToRoutine(at: now)
        #expect(!after.edited)
        #expect(after.exercises.map(\.exerciseId) == ["db", "free", "cable"])
        #expect(after.base?.exercises.map(\.exerciseId) == ["bb", "free", "cable"])
        #expect(after.gymSwaps[benchId]?.exerciseId == "bb")
        #expect(after.exercisesMatchBase)
    }

    @Test func setEditsOnASwappedItemAreNotSavedToTheRoutine() throws {
        let plan = scheduled().adapted(by: dumbbellGym).editingSets(benchId, typed)
        #expect(!plan.canSaveToRoutine)
        #expect(!plan.edited)
        #expect(plan.hasTodayChanges, "the typed sets must survive a relaunch")
        #expect(plan.sets(for: benchId) == typed)
        #expect(plan.routineToStart?.exercises.map(\.exerciseId) == ["db", "free"])
        #expect(plan.routineWithEdits(at: now) == nil)
    }

    // MARK: Reloads

    @Test func setEditsOnASwappedItemSurviveReload() throws {
        let (store, cleanup) = try store()
        defer { cleanup() }
        let plan = scheduled().adapted(by: dumbbellGym).editingSets(benchId, typed)
        store.save(plan)

        let loaded = try #require(store.load(day: day, routines: [routine], scheduled: routine.id))
        let again = loaded.adapted(by: dumbbellGym)
        #expect(again.exercises.map(\.exerciseId) == ["db", "free"])
        #expect(again.sets(for: benchId) == typed)
        #expect(!again.edited)
        #expect(!again.canSaveToRoutine)
    }

    @Test func setEditsAreDroppedWhenTheExerciseChanges() {
        let plan = scheduled().adapted(by: dumbbellGym).editingSets(benchId, typed)
        let elsewhere = plan.adapted(by: kettlebellGym)
        #expect(elsewhere.exercises[0].exerciseId == "kb")
        #expect(elsewhere.sets(for: benchId) == nil)
    }

    @Test func rebasedKeepsSwapsOfItemsStillThere() {
        let swapped = scheduled().adapted(by: dumbbellGym).editingSets(benchId, typed)
        let changedRoutine = routine.with(exercises: [
            RoutineExercise(id: benchId, exerciseId: "bb", sets: 5, reps: 5), routine.exercises[1],
        ])
        let rebased = swapped.rebased(on: changedRoutine)
        #expect(rebased.exercises.map(\.exerciseId) == ["db", "free"])
        #expect(rebased.gymSwaps[benchId]?.sets == 5, "the planned item is the routine's current version")
        #expect(rebased.sets(for: benchId) == typed)
        #expect(!rebased.edited)
        #expect(rebased.adapted(by: dumbbellGym).exercises[0].exerciseId == "db")
    }

    @Test func rebasedDropsSwapsWhenThePlannedExerciseChanged() {
        let swapped = scheduled().adapted(by: dumbbellGym).editingSets(benchId, typed)
        let changedRoutine = routine.with(exercises: [
            RoutineExercise(id: benchId, exerciseId: "cable", sets: 3, reps: 8), routine.exercises[1],
        ])
        let rebased = swapped.rebased(on: changedRoutine)
        #expect(rebased.exercises.map(\.exerciseId) == ["cable", "free"])
        #expect(rebased.gymSwaps.isEmpty)
        #expect(rebased.sets(for: benchId) == nil)
    }

    // MARK: Hand choices

    @Test func replacingPinsAndClearsTheSwap() {
        let replaced = scheduled().adapted(by: dumbbellGym)
            .replacing(benchId, with: RoutineExercise(id: benchId, exerciseId: "cable", sets: 3, reps: 12))
        #expect(replaced.gymSwaps.isEmpty)
        #expect(replaced.gymPinned == [benchId])
        #expect(replaced.edited)
        #expect(replaced.adapted(by: dumbbellGym).exercises[0].exerciseId == "cable", "a pinned item is not swapped")
    }

    @Test func addingPins() {
        let item = RoutineExercise(exerciseId: "cable", sets: 3, reps: 12)
        let added = scheduled().adapted(by: dumbbellGym).adding([item])
        #expect(added.gymPinned == [item.id])
        #expect(added.gymSwaps[benchId]?.exerciseId == "bb", "other swaps stay")
    }

    @Test func deletingClearsBoth() {
        let pinned = scheduled().adapted(by: dumbbellGym)
            .replacing(freeId, with: RoutineExercise(id: freeId, exerciseId: "cable", sets: 3, reps: 8))
        let gone = pinned.deleting(freeId).deleting(benchId)
        #expect(gone.gymPinned.isEmpty)
        #expect(gone.gymSwaps.isEmpty)
        #expect(gone.exercises.isEmpty)
    }

    @Test func pinnedSurvivesReload() throws {
        let (store, cleanup) = try store()
        defer { cleanup() }
        let pinned = scheduled().adapted(by: dumbbellGym).usingPlanned(benchId)
        store.save(pinned)
        let loaded = try #require(store.load(day: day, routines: [routine], scheduled: routine.id))
        #expect(loaded.gymPinned == [benchId])
        let again = loaded.adapted(by: dumbbellGym)
        #expect(again.exercises.map(\.exerciseId) == ["bb", "free"])
        #expect(again.gymSwaps.isEmpty)
    }

    @Test func pinnedPlannedExerciseIsStoredEvenThoughNothingIsEdited() {
        let pinned = scheduled().adapted(by: dumbbellGym).usingPlanned(benchId)
        #expect(!pinned.edited)
        #expect(pinned.hasTodayChanges)
    }

    @Test func usePlannedAnywayRestoresAndPins() {
        let plan = scheduled().adapted(by: dumbbellGym).editingSets(benchId, typed)
        let used = plan.usingPlanned(benchId)
        #expect(used.exercises == routine.exercises)
        #expect(used.exercisesMatchBase)
        #expect(!used.edited)
        #expect(used.gymPinned == [benchId])
        #expect(used.gymSwaps.isEmpty)
        #expect(used.sets(for: benchId) == nil, "the sets belonged to the replacement")
    }

    // MARK: Built workouts

    @Test func builtPlan() throws {
        let items = [RoutineExercise(exerciseId: "bb", sets: 3, reps: 8)]
        let plan = TodayPlan.built(name: "Back + Arms", items: items, day: day)
        #expect(plan.title == "Back + Arms")
        #expect(plan.routineToStart?.name == "Back + Arms")
        #expect(!plan.canSaveToRoutine)
        #expect(plan.kind == .built)
        #expect(plan.hasTodayChanges)
        let decoded = try JSONDecoder().decode(TodayPlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded == plan)
        #expect(plan.adapted(by: dumbbellGym).exercises[0].exerciseId == "db")
    }

    @Test func plansStoredBeforeThisStillDecode() throws {
        let old = scheduled().editingSets(benchId, typed)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["gymSwaps"] = nil
        json["gymPinned"] = nil
        json["builtName"] = nil
        let decoded = try JSONDecoder().decode(TodayPlan.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.gymSwaps.isEmpty)
        #expect(decoded.gymPinned.isEmpty)
        #expect(decoded == old)
    }

    @Test func switchingRoutinesDropsSwapsAndPins() {
        let other = Routine(name: "Pull", exercises: [RoutineExercise(exerciseId: "free", sets: 3, reps: 8)])
        let switched = scheduled().adapted(by: dumbbellGym).usingPlanned(benchId).switched(to: other)
        #expect(switched.gymSwaps.isEmpty)
        #expect(switched.gymPinned.isEmpty)
    }
}
