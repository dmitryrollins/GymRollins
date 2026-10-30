import Foundation
import Testing
@testable import GymCore

/// Variety: recent exercises are skipped, repeats are explained, Rebuild avoids the current result.
@Suite struct WorkoutBuilderVarietyTests {
    private let day = 20_400

    private func build(_ inventory: GymInventory, _ muscles: [BuildMuscle], _ length: BuildLength,
                       history: [Workout] = [], avoid: Set<String> = []) -> BuiltWorkout {
        WorkoutBuilder(matcher: GymFixtures.matcher(inventory), exercises: GymFixtures.exercises, history: history)
            .build(BuildRequest(muscles: muscles, length: length, date: GymFixtures.date(day: day), avoid: avoid))
    }

    @Test func exercisesFromRecentWorkoutsForTheMuscleAreSkipped() {
        let fresh = build(GymFixtures.iron, [.chest], .short)
        let history = [GymFixtures.workout(day: day - 1, fresh.items.map(\.exercise.exerciseId))]
        let next = build(GymFixtures.iron, [.chest], .short, history: history)
        #expect(Set(next.items.map(\.exercise.exerciseId)).isDisjoint(with: fresh.items.map(\.exercise.exerciseId)))
        #expect(next.items.allSatisfy { $0.repeatOf == nil })
    }

    @Test func onlyTheLastThreeWorkoutsForTheMuscleCount() {
        let machines = GymInventory(gymName: "Machines", listings: [
            InventoryListing(id: GymFixtures.id(70), kindId: "pec-deck", confirmCount: 5),
            InventoryListing(id: GymFixtures.id(71), kindId: "chest-press-machine", confirmCount: 4),
            InventoryListing(id: GymFixtures.id(72), kindId: "cable-station", confirmCount: 3),
        ])
        let old = GymFixtures.workout(day: day - 9, ["c-pec-deck"])
        let recent = (1...3).map { GymFixtures.workout(day: day - $0, ["c-machine-press"]) }
        let built = build(machines, [.chest], .short, history: [old] + recent)
        let ids = built.items.map(\.exercise.exerciseId)
        #expect(ids.contains("c-pec-deck"), "the 4th-latest chest workout no longer counts")
        #expect(!ids.contains("c-machine-press"))
        #expect(built.items.allSatisfy { $0.repeatOf == nil })
    }

    @Test func workoutsForOtherMusclesDontCount() {
        // Three leg days don't push the chest day out of the last 3 chest workouts.
        let legDays = (1...3).map { GymFixtures.workout(day: day - $0, ["l-leg-press"]) }
        let chestDay = GymFixtures.workout(day: day - 4, ["c-machine-press"])
        let built = build(GymFixtures.iron, [.chest], .long, history: legDays + [chestDay])
        #expect(!built.items.map(\.exercise.exerciseId).contains("c-machine-press"))
    }

    @Test func aRepeatIsUsedWhenNothingElseFitsAndCarriesItsLastDay() throws {
        let history = [GymFixtures.workout(day: day - 2, ["b-kb-row"])]
        let built = build(GymFixtures.home, [.back], .short, history: history)
        let row = try #require(built.items.first { $0.exercise.exerciseId == "b-kb-row" })
        #expect(row.repeatOf == GymFixtures.workout(day: day - 2, []).startedAt)
    }

    @Test func repeatsPickTheLeastRecentlyDoneFirst() throws {
        // One arms slot (3 slots over 3 chips); both kettlebell arm exercises are recent, the skull crusher less so.
        let history = [GymFixtures.workout(day: day - 1, ["a-kb-curl"]), GymFixtures.workout(day: day - 2, ["a-kb-skull"])]
        let built = build(GymFixtures.home, [.arms, .back, .chest], .short, history: history)
        let arms = try #require(built.items.first { $0.muscle == .arms })
        #expect(arms.exercise.exerciseId == "a-kb-skull")
        #expect(arms.repeatOf == GymFixtures.workout(day: day - 2, []).startedAt)
    }

    @Test func rebuildAvoidsTheCurrentResultWithoutMarkingRepeats() {
        let first = build(GymFixtures.iron, [.chest], .short)
        let avoid = Set(first.items.map(\.exercise.exerciseId))
        let second = build(GymFixtures.iron, [.chest], .short, avoid: avoid)
        #expect(Set(second.items.map(\.exercise.exerciseId)).isDisjoint(with: avoid))
        let thin = build(GymFixtures.home, [.arms], .short, avoid: ["a-kb-curl", "a-kb-skull"])
        #expect(thin.items.count == 2, "with nothing else, Rebuild returns the same exercises")
        #expect(thin.items.allSatisfy { $0.repeatOf == nil })
    }
}
