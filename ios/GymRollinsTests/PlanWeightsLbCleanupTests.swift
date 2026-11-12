import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymRollins

/// Plan 38's one-time cleanup: in lb, plan weights saved before the pound number (agents' kg such as 20.3 kg, which
/// shows as 44.8 lb) get one, on the exercise's grid, and sync once.
@MainActor
@Suite struct PlanWeightsLbCleanupTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private func pounds(_ v: Double) -> PoundWeight { PoundWeight.entered(v, unit: .lb) }
    private let library = ExerciseLibrary(exercises: [
        Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
        Exercise(id: "0541", name: "kettlebell one arm row", bodyPart: "back", equipment: "kettlebell", target: "upper back"),
        Exercise(id: "0251", name: "chest dip", bodyPart: "chest", equipment: "body weight", target: "pectorals"),
    ])
    private let setAt = Date(timeIntervalSince1970: 1_000)
    private let container: ModelContainer
    private let routines: RoutineRepository
    private let defaults: UserDefaults

    init() throws {
        container = try GymStore.container(inMemory: true)
        routines = RoutineRepository(context: container.mainContext, now: { Date(timeIntervalSince1970: 9_000) })
        defaults = try #require(UserDefaults(suiteName: "PlanWeightsLbCleanupTests.\(UUID())"))
    }

    private func seed(_ items: [RoutineExercise], name: String = "Push") throws -> Routine {
        let routine = Routine(name: name, exercises: items)
        try routines.upsert(routine)
        try markSynced()
        return routine
    }

    /// Renames a saved routine behind the repository's back, as an older build or a pull could have stored it.
    private func rename(_ id: UUID, to name: String) throws {
        try container.mainContext.fetch(FetchDescriptor<RoutineRecord>()).first { $0.id == id }?.name = name
        try container.mainContext.save()
    }

    /// As after a sync: nothing left to push.
    private func markSynced() throws {
        try container.mainContext.fetch(FetchDescriptor<RoutineRecord>()).forEach { $0.dirty = false }
        try container.mainContext.save()
    }

    private func isDirty(_ id: UUID) throws -> Bool {
        try container.mainContext.fetch(FetchDescriptor<RoutineRecord>()).first { $0.id == id }?.dirty == true
    }

    private func run(_ profile: Profile = Profile(unit: .lb)) throws -> Int {
        try PlanWeightsLbCleanup.runOnce(routines: routines, profile: profile, library: library, defaults: defaults)
    }

    @Test func anAgentsKgWeightOnABarbellBecomes45LbAndSyncsOnce() throws {
        let routine = try seed([RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, weightKg: 20.3, weightSetAt: setAt)])
        #expect(try run() == 1)
        let item = try #require(try routines.routine(routine.id)?.exercises.first)
        #expect(item.weight == pounds(45), "20.41 kg, 45 lb")
        #expect(item.weightSetAt == setAt, "the cleanup isn't a planned weight: progression is unchanged")
        #expect(try isDirty(routine.id), "it syncs")
        #expect(defaults.bool(forKey: PlanWeightsLbCleanup.flagKey))

        try markSynced()
        #expect(try run() == 0, "a second launch changes nothing")
        #expect(try routines.routine(routine.id)?.exercises.first?.weight == pounds(45))
        #expect(try !isDirty(routine.id))
    }

    @Test func cleaningTwiceChangesNothing() throws {
        let routine = Routine(name: "Push", exercises: [RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, weightKg: 20.3)])
        let rounder = { (_: String) in LoadRounder.barbellLb }
        let once = try #require(PlanWeightsLbCleanup.cleaned(routine, rounder: rounder))
        #expect(PlanWeightsLbCleanup.cleaned(once, rounder: rounder) == nil)
    }

    @Test func aWeightAlreadyAPoundNumberKeepsItsKgAndGainsThePoundNumber() throws {
        // 44 lb typed for the kettlebell: on the ½ lb grid but not the 2.5 lb dumbbell grid. It isn't moved to 45.
        let routine = try seed([RoutineExercise(exerciseId: "0541", sets: 3, reps: 12, weightKg: lb(44))])
        #expect(try run() == 1)
        #expect(try routines.routine(routine.id)?.exercises.first?.weight == pounds(44))
    }

    @Test func weightsWithAPoundNumberAndBodyweightAreLeftAlone() throws {
        let routine = try seed([
            RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, weightKg: lb(137.5), weightLb: 137.5),
            RoutineExercise(exerciseId: "0251", sets: 3, reps: 10),
        ])
        #expect(try run() == 0)
        #expect(try routines.routine(routine.id)?.exercises.map(\.weight) == [pounds(137.5), nil])
        #expect(try !isDirty(routine.id))
        #expect(defaults.bool(forKey: PlanWeightsLbCleanup.flagKey), "done: it doesn't look again")
    }

    @Test func anEmptyStoreWaitsForAPlanBeforeSettingTheFlag() throws {
        #expect(try run() == 0)
        #expect(!defaults.bool(forKey: PlanWeightsLbCleanup.flagKey), "a reinstall or sign-in pulls the plan later")

        let routine = try seed([RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, weightKg: 20.3)])
        #expect(try run() == 1)
        #expect(try routines.routine(routine.id)?.exercises.first?.weight == pounds(45))
        #expect(defaults.bool(forKey: PlanWeightsLbCleanup.flagKey))
    }

    @Test func aRoutineThatCantBeSavedIsSkippedAndTheOthersAreCleaned() throws {
        // Each routine its own item: item ids are unique in the store.
        let agentsKg = { [RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, weightKg: 20.3)] }
        let bad = try seed(agentsKg(), name: "Bad")
        let good = try seed(agentsKg(), name: "Good")
        try rename(bad.id, to: " ") // no name: `DomainLimits` refuses to save it
        #expect(try run() == 1)
        #expect(try routines.routine(good.id)?.exercises.first?.weight == pounds(45))
        #expect(try isDirty(good.id))
        #expect(try routines.routine(bad.id)?.exercises.first?.weight == PoundWeight(kg: 20.3, lb: nil))
        #expect(try !isDirty(bad.id))
        #expect(defaults.bool(forKey: PlanWeightsLbCleanup.flagKey), "a retry would fail the same way, so it's done")
    }

    @Test func inKgNothingChangesAndItWaitsForPounds() throws {
        let routine = try seed([RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, weightKg: 20.3)])
        #expect(try run(Profile(unit: .kg)) == 0)
        #expect(try routines.routine(routine.id)?.exercises.first?.weight == PoundWeight(kg: 20.3, lb: nil))
        #expect(!defaults.bool(forKey: PlanWeightsLbCleanup.flagKey), "runs on the first launch in lb")
    }

    @Test func aLaunchCleansTheSeededPlanAndAFreshStoreForgetsTheFlag() throws {
        defaults.set(true, forKey: PlanWeightsLbCleanup.flagKey) // left over from an earlier store
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]), defaults: defaults)
        let weights = try env.routines.all().flatMap(\.exercises).compactMap(\.weight)
        #expect(!weights.isEmpty)
        #expect(weights.allSatisfy { $0.lb != nil }, "every seeded lb weight has its pound number")
        #expect(defaults.bool(forKey: PlanWeightsLbCleanup.flagKey))
    }
}
