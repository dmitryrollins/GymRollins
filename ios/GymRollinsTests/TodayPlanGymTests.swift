import Foundation
import GymCore
import Testing
@testable import GymRollins

/// The app never swaps exercises for the gym (owner, 2026-11-18): only the owner does, with Replace. Builds before
/// that stored swapped plans (`gymSwaps`: item id → the planned item, `exercises` holding the replacement); those
/// plans come back as planned, without the sets typed on the replacement.
@Suite struct TodayPlanGymTests {
    private let day = "2026-10-30"
    private let now = ISO8601DateFormatter().date(from: "2026-10-30T09:00:00Z")!

    private let routine = Routine(name: "Push", exercises: [
        RoutineExercise(exerciseId: "bb", sets: 3, reps: 8, weightKg: 60),
        RoutineExercise(exerciseId: "free", sets: 3, reps: 10),
    ])

    private func scheduled() -> TodayPlan {
        TodayPlan.make(scheduled: routine, routines: [routine], lastDone: [:], day: day)
    }

    private let typed = [WorkoutSet(weightKg: 30, reps: 12)]
    private let typedFree = [WorkoutSet(weightKg: 0, reps: 15)]

    private var benchId: UUID { routine.exercises[0].id }
    private var freeId: UUID { routine.exercises[1].id }

    /// What an older build stored at a dumbbell gym: the barbell press shown as a dumbbell press (same item id), sets
    /// typed on both items, the free item pinned.
    private func legacyJSON() throws -> Data {
        let replacement = RoutineExercise(id: benchId, exerciseId: "db", sets: 3, reps: 8)
        let shown = TodayPlan(day: day, kind: .scheduled, base: routine,
                              exercises: [replacement, routine.exercises[1]], edited: true,
                              setOverrides: [benchId: typed, freeId: typedFree], unsavedSetEdits: [freeId])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(shown)) as? [String: Any])
        json["gymSwaps"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([benchId: routine.exercises[0]]))
        json["gymPinned"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Set([freeId])))
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func defaults() throws -> (UserDefaults, () -> Void) {
        let suite = "today-plan-gym-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    // MARK: Plans stored by older builds

    @Test func aLegacySwappedPlanDecodesToThePlannedExercises() throws {
        let decoded = try JSONDecoder().decode(TodayPlan.self, from: legacyJSON())
        #expect(decoded.exercises == routine.exercises)
        #expect(decoded.exercisesMatchBase)
        #expect(decoded.sets(for: benchId) == nil, "the sets were typed on the replacement")
        #expect(decoded.sets(for: freeId) == typedFree)
        #expect(decoded.unsavedSetEdits == [freeId])
        #expect(decoded.routineToStart?.exercises.map(\.exerciseId) == ["bb", "free"])
        let saved = try #require(decoded.routineWithEdits(at: now))
        #expect(saved.exercises[0] == routine.exercises[0], "the planned exercise is written untouched")
    }

    @Test func aLegacyPlanReEncodesWithoutGymKeys() throws {
        let decoded = try JSONDecoder().decode(TodayPlan.self, from: legacyJSON())
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(json["gymSwaps"] == nil)
        #expect(json["gymPinned"] == nil)
        #expect(try JSONDecoder().decode(TodayPlan.self, from: JSONEncoder().encode(decoded)) == decoded)
    }

    /// Through the store, as Today reads it (UserDefaults `gymrollins.todayPlan`).
    @Test func todaysStoredLegacyPlanLoadsAsPlanned() throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        defaults.set(try legacyJSON(), forKey: TodayPlanStore.key)
        let loaded = try #require(TodayPlanStore(defaults: defaults).load(day: day, routines: [routine],
                                                                         scheduled: routine.id))
        #expect(loaded.exercises == routine.exercises)
        #expect(loaded.sets(for: benchId) == nil)
    }

    /// A later day's change, stored by an older build (`LaterDayPlanStore`, yyyy-MM-dd → plan).
    @Test func aLaterDaysStoredLegacyPlanLoadsAsPlanned() throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        let plan = try JSONSerialization.jsonObject(with: legacyJSON())
        defaults.set(try JSONSerialization.data(withJSONObject: [day: plan]), forKey: LaterDayPlanStore.key)
        let loaded = try #require(LaterDayPlanStore(defaults: defaults).plan(day: day, routines: [routine],
                                                                             scheduled: routine.id))
        #expect(loaded.exercises == routine.exercises)
        #expect(loaded.sets(for: benchId) == nil)
        #expect(loaded.sets(for: freeId) == typedFree)
    }

    @Test func plansStoredBeforeSetEditingOrBuiltWorkoutsStillDecode() throws {
        let old = scheduled().editingSets(benchId, typed)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["builtName"] = nil
        json["builtListings"] = nil
        let decoded = try JSONDecoder().decode(TodayPlan.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == old)
    }

    // MARK: Hand choices

    /// Save Changes would write the same exercise twice: the app addresses plan exercises by id.
    @Test func replacingOntoAnExerciseAlreadyInThePlanIsRefused() {
        let plan = scheduled()
        #expect(plan.replacing(freeId, with: RoutineExercise(exerciseId: "bb", sets: 3, reps: 8)) == plan)
        let replaced = plan.replacing(benchId, with: RoutineExercise(id: benchId, exerciseId: "db", sets: 3, reps: 8))
        #expect(replaced.exercises.map(\.exerciseId) == ["db", "free"])
        #expect(replaced.edited)
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
    }
}
