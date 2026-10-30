import Foundation
import Testing
@testable import GymCore

@Suite struct WorkoutBuilderTests {
    private let day = 20_400

    private func builder(_ inventory: GymInventory, history: [Workout] = [],
                         preferences: [String: ExercisePreference] = [:],
                         logged: [String: Int] = [:]) -> WorkoutBuilder {
        WorkoutBuilder(matcher: GymFixtures.matcher(inventory), exercises: GymFixtures.exercises, history: history,
                       loggedCounts: logged, preferences: preferences)
    }

    private func request(_ muscles: [BuildMuscle], _ length: BuildLength, avoid: Set<String> = []) -> BuildRequest {
        BuildRequest(muscles: muscles, length: length, date: GymFixtures.date(day: day), avoid: avoid)
    }

    @Test func homeBackAndArmsIsShortWithAThinNoticeForBack() {
        let built = builder(GymFixtures.home).build(request([.back, .arms], .medium))
        #expect(built.requestedSlots == 5)
        #expect(built.items.map(\.exercise.exerciseId).sorted() == ["a-kb-curl", "a-kb-skull", "b-kb-row"])
        #expect(built.thin == [ThinInventoryNotice(muscle: .back, itemCount: 1)])
        #expect(built.items.allSatisfy { !$0.isBodyweightFill && $0.repeatOf == nil })
    }

    @Test func itemsUseDefaultTargetsAndNoPlannedWeight() throws {
        let item = try #require(builder(GymFixtures.home).build(request([.back], .short)).items.first)
        let defaults = RoutineExercise.defaults(exerciseId: "b-kb-row", mode: .reps, barbell: false)
        #expect(item.exercise.exerciseId == "b-kb-row")
        #expect(item.exercise.sets == defaults.sets && item.exercise.reps == defaults.reps)
        #expect(item.exercise.repsMin == defaults.repsMin && item.exercise.incKg == defaults.incKg)
        #expect(item.exercise.weightKg == nil)
        #expect(item.muscle == .back)
        #expect(item.match.loadListingId == GymFixtures.homeKettlebells.id)
    }

    @Test func atMostTwoExercisesPerMachineThenBodyweightFills() {
        let cablesOnly = GymInventory(gymName: "Cables", listings: [
            InventoryListing(id: GymFixtures.id(50), kindId: "cable-station", loads: .stack(maxKg: 90, stepKg: 4.5)),
        ])
        let built = builder(cablesOnly).build(request([.chest], .medium))
        let ids = built.items.map(\.exercise.exerciseId)
        #expect(ids.filter { $0.hasPrefix("c-cable") }.count == 2)
        #expect(ids.last == "c-pushup")
        #expect(built.items.last?.isBodyweightFill == true)
        #expect(built.items.count == 3, "4 slots, but only 2 cable exercises and 1 push-up fit")
        #expect(built.thin == [ThinInventoryNotice(muscle: .chest, itemCount: 1)])
    }

    @Test func freeWeightsAreNotCappedLikeMachines() {
        let built = builder(GymFixtures.home).build(request([.arms], .medium))
        #expect(built.items.count == 2, "only two arm exercises exist for kettlebells")
        #expect(built.items.allSatisfy { $0.match.loadListingId == GymFixtures.homeKettlebells.id })
    }

    @Test func preferencesRankMoreFirstAndDropNever() {
        let built = builder(GymFixtures.iron, preferences: ["c-pec-deck": .more, "c-bb-bench": .never])
            .build(request([.chest], .short))
        let ids = built.items.map(\.exercise.exerciseId)
        #expect(ids.contains("c-pec-deck"))
        #expect(!ids.contains("c-bb-bench"))
    }

    @Test func moreConfirmedListingsRankFirst() {
        // Back at Iron: barbell (9 confirmations), dumbbells (8), the cable station behind the pulldown (7), and
        // the power rack for pull-ups (4) last.
        let built = builder(GymFixtures.iron).build(request([.back], .short))
        #expect(built.items.map(\.exercise.exerciseId) == ["b-bb-row", "b-db-row", "b-pulldown"])
    }

    @Test func compoundExercisesComeFirst() {
        let built = builder(GymFixtures.iron).build(request([.chest], .long))
        let compound = built.items.map { MuscleTaxonomy.contributions(for: exercise($0)).count >= 2 }
        #expect(compound == compound.sorted { $0 && !$1 })
    }

    @Test func sameInputGivesTheSameWorkout() {
        let a = builder(GymFixtures.iron).build(request([.chest, .back], .long))
        let b = builder(GymFixtures.iron).build(request([.chest, .back], .long))
        #expect(a == b)
    }

    @Test func noChipsBuildsNothing() {
        #expect(builder(GymFixtures.iron).build(request([], .long))
            == BuiltWorkout(items: [], thin: [], requestedSlots: 0))
    }

    private func exercise(_ item: BuiltItem) -> Exercise {
        GymFixtures.exercises.first { $0.id == item.exercise.exerciseId }!
    }
}
