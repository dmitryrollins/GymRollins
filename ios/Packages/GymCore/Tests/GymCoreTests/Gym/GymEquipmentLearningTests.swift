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

    /// "Flat or adjustable bench": the workout can't say which one was there.
    @Test func aChoiceOfKindsAddsNothing() {
        #expect(kinds(["c-db-press"]) == ["dumbbells"])
        #expect(kinds(["b-pullup", "b-pulldown"]).isEmpty)
        #expect(kinds(["c-bb-bench"]) == ["barbell"])
    }

    @Test func eachKindIsAddedOnceInTheOrderFirstNeeded() {
        #expect(kinds(["a-db-curl", "b-db-row", "a-cable-pushdown", "c-cable-fly", "c-db-press"])
            == ["dumbbells", "cable-station"])
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
}
