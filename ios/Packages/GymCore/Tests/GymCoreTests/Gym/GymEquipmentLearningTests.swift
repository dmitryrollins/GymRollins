import Foundation
import Testing
@testable import GymCore

/// A finished workout says what its gym has: every exercise with a done set was done there (owner, 2026-11-18).
@Suite struct GymEquipmentLearningTests {
    private let known = Set(GymFixtures.kinds.map(\.id))

    private func kinds(_ exerciseIds: [String], listed: Set<String> = [], known: Set<String>? = nil) -> [String] {
        GymEquipmentLearning.kindsShown(by: GymFixtures.workout(day: 1, exerciseIds),
                                        requirements: GymFixtures.requirements, knownKinds: known ?? self.known,
                                        listedKinds: listed)
    }

    @Test func anExerciseDoneAddsWhatItNeeds() {
        #expect(kinds(["a-db-curl", "a-cable-pushdown"]) == ["dumbbells", "cable-station"])
        #expect(kinds(["b-bb-row"]) == ["barbell"])
    }

    @Test func whatTheGymListsAddsNothing() {
        #expect(kinds(["a-kb-curl", "b-kb-row"], listed: ["kettlebells", "flat-bench"]).isEmpty)
    }

    /// "Flat or adjustable bench": the workout can't say which one was there, so the first kind of the choice (the one
    /// the exercise is named for) is added.
    @Test func aChoiceOfKindsAddsItsFirstKind() {
        #expect(kinds(["c-db-press"]) == ["dumbbells", "flat-bench"])
        #expect(kinds(["b-pullup"]) == ["pull-up-bar"])
        #expect(kinds(["b-pulldown"]) == ["lat-pulldown"])
        #expect(kinds(["c-bb-bench"]) == ["barbell", "flat-bench", "power-rack"])
    }

    @Test func aChoiceTheGymAlreadyCoversAddsNothing() {
        #expect(kinds(["b-pulldown"], listed: ["cable-station"]).isEmpty)
        #expect(kinds(["c-db-press"], listed: ["dumbbells", "adjustable-bench"]).isEmpty)
        #expect(kinds(["c-bb-bench"], listed: ["bench-press-station"]) == ["barbell"])
    }

    /// An earlier exercise's kind covers a later exercise's choice.
    @Test func aChoiceAnEarlierExerciseCoveredAddsNothing() {
        #expect(kinds(["c-cable-fly", "b-pulldown"]) == ["cable-station"])
        #expect(kinds(["b-pulldown", "c-cable-fly"]) == ["lat-pulldown", "cable-station"])
    }

    @Test func aChoiceOfKindsTheAppDoesNotKnowAddsTheFirstOneItKnows() {
        #expect(kinds(["b-pulldown"], known: known.subtracting(["lat-pulldown"])) == ["cable-station"])
        #expect(kinds(["b-pulldown"], known: known.subtracting(["lat-pulldown", "cable-station"])).isEmpty)
    }

    @Test func eachKindIsAddedOnceInTheOrderFirstNeeded() {
        #expect(kinds(["a-db-curl", "b-db-row", "a-cable-pushdown", "c-cable-fly", "c-db-press"])
            == ["dumbbells", "flat-bench", "cable-station"])
    }

    @Test func bodyweightAndUnmappedExercisesAddNothing() {
        #expect(kinds(["c-pushup", "x-shrug"]).isEmpty)
    }

    @Test func aKindThisAppDoesNotKnowIsNotAdded() {
        #expect(kinds(["l-leg-press", "a-db-curl"], known: known.subtracting(["leg-press"])) == ["dumbbells"])
    }

    /// A swapped-out exercise isn't in the workout; one left with no set done wasn't done here either.
    @Test func onlyExercisesWithADoneSetCount() {
        let workout = Workout(startedAt: GymFixtures.date(day: 1), name: "Day 1", entries: [
            WorkoutEntry(exerciseId: "a-db-curl", sets: [WorkoutSet(weightKg: 10, reps: 10, done: false)]),
            WorkoutEntry(exerciseId: "a-cable-pushdown", sets: []),
            WorkoutEntry(exerciseId: "b-bb-row", sets: [WorkoutSet(weightKg: 20, reps: 10, done: true, warmup: true)]),
        ])
        let shown = GymEquipmentLearning.kindsShown(by: workout, requirements: GymFixtures.requirements,
                                                    knownKinds: known, listedKinds: [])
        #expect(shown == ["barbell"])
    }

    // MARK: Weights

    private func workout(_ entries: [(String, [Double])]) -> Workout {
        Workout(startedAt: GymFixtures.date(day: 1), endedAt: GymFixtures.date(day: 1).addingTimeInterval(3_600),
                name: "Day 1", entries: entries.map { id, kg in
                    WorkoutEntry(exerciseId: id, sets: kg.map { WorkoutSet(weightKg: $0, reps: 8, done: true) })
                })
    }

    private func matcher(_ listings: [InventoryListing]) -> InventoryMatcher {
        GymFixtures.matcher(GymInventory(gymName: "Garage", listings: listings))
    }

    private let dumbbells = InventoryListing(id: GymFixtures.id(1), kindId: "dumbbells", isOwn: true)
    private let bench = InventoryListing(id: GymFixtures.id(2), kindId: "flat-bench", isOwn: true)
    private let barbell = InventoryListing(id: GymFixtures.id(3), kindId: "barbell", isOwn: true)
    private let kettlebells = InventoryListing(id: GymFixtures.id(4), kindId: "kettlebells", isOwn: true)

    @Test func theDumbbellsGetTheWeightsOfTheDoneSetsTheyDecide() {
        let shown = GymEquipmentLearning.weightsShown(
            by: workout([("a-db-curl", [12, 14]), ("b-db-row", [20, 14, 20])]), matcher: matcher([dumbbells, bench]))
        #expect(shown == [dumbbells.id: [12, 14, 20]])
    }

    /// The bench doesn't decide the weight of the dumbbell press, and neither does a barbell's weight reach a bell.
    @Test func aBenchOrBarbellNeverGetsWeights() {
        let shown = GymEquipmentLearning.weightsShown(
            by: workout([("c-db-press", [16]), ("c-bb-bench", [60]), ("a-kb-curl", [12])]),
            matcher: matcher([dumbbells, bench, barbell, kettlebells]))
        #expect(shown == [dumbbells.id: [16], kettlebells.id: [12]])
    }

    @Test func onlyDoneSetsWithAWeightCount() {
        let sets = [WorkoutSet(weightKg: 10, reps: 8, done: false), WorkoutSet(weightKg: 0, reps: 8, done: true),
                    WorkoutSet(weightKg: 12, reps: 8, done: true)]
        let shown = GymEquipmentLearning.weightsShown(
            by: Workout(startedAt: GymFixtures.date(day: 1), name: "Day 1",
                        entries: [WorkoutEntry(exerciseId: "a-db-curl", sets: sets)]),
            matcher: matcher([dumbbells]))
        #expect(shown == [dumbbells.id: [12]])
    }

    /// A warm-up is a done set with a real weight: its pair of dumbbells is at the gym.
    @Test func aDoneWarmUpSetCounts() {
        let sets = [WorkoutSet(weightKg: 8, reps: 10, done: true, warmup: true),
                    WorkoutSet(weightKg: 14, reps: 8, done: true)]
        let shown = GymEquipmentLearning.weightsShown(
            by: Workout(startedAt: GymFixtures.date(day: 1), name: "Day 1",
                        entries: [WorkoutEntry(exerciseId: "a-db-curl", sets: sets)]),
            matcher: matcher([dumbbells]))
        #expect(shown == [dumbbells.id: [8, 14]])
    }

    /// Two dumbbell listings: the weights go to the one the matcher picks for the exercise, the other stays bare.
    @Test func withTwoListingsOfAKindOnlyTheOneTheMatcherPicksGetsTheWeights() {
        let first = InventoryListing(id: GymFixtures.id(5), kindId: "dumbbells", confirmCount: 3)
        let second = InventoryListing(id: GymFixtures.id(6), kindId: "dumbbells", confirmCount: 1)
        let m = matcher([second, first])
        let shown = GymEquipmentLearning.weightsShown(by: workout([("a-db-curl", [12])]), matcher: m)
        #expect(shown == [first.id: [12]])
    }

    @Test func noListingNoWeightsAndUnmappedExercisesAreSkipped() {
        let shown = GymEquipmentLearning.weightsShown(
            by: workout([("a-db-curl", [12]), ("x-shrug", [30]), ("c-pushup", [5])]), matcher: matcher([bench]))
        #expect(shown.isEmpty)
    }

    @Test func weightsWithinTheToleranceCountOnce() {
        let shown = GymEquipmentLearning.weightsShown(
            by: workout([("a-kb-curl", [24.04, 24, 12])]), matcher: matcher([kettlebells]))
        #expect(shown == [kettlebells.id: [12, 24]])
    }
}

@Suite struct LearnedWeightsTests {
    @Test func distinctSortsDropsDuplicatesAndOutOfRangeWeights() {
        #expect(LearnedWeights.distinct([20, 10, 10.1, 0, -5, 600, 0.1, 15]) == [10, 15, 20])
    }

    @Test func mergedKeepsWhatIsThereAndAddsWhatIsNew() {
        #expect(LearnedWeights.merged([10, 20], with: [15, 20.1, 10]) == [10, 15, 20])
        #expect(LearnedWeights.merged([], with: [12, 8]) == [8, 12])
    }

    @Test func mergedNeverGrowsPastTheLimit() {
        let existing = (1...DomainLimits.listingFixedWeightsMax).map { Double($0) }
        #expect(LearnedWeights.merged(existing, with: [100.5]) == existing)
    }
}
