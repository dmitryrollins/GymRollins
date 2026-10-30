import Foundation
import Testing
@testable import GymCore

@Suite struct GymAdapterTests {
    private func planned(_ exerciseId: String, n: Int, sets: Int = 4, reps: Int = 8) -> RoutineExercise {
        RoutineExercise(id: GymFixtures.id(100 + n), exerciseId: exerciseId, sets: sets, reps: reps, repsMin: 6,
                        weightKg: 60, incKg: 2.27, supersetGroup: n == 2 ? "A" : nil, weightSetAt: .distantPast)
    }

    private func adapter(_ inventory: GymInventory, preferences: [String: ExercisePreference] = [:],
                         logged: [String: Int] = [:]) -> GymAdapter {
        GymAdapter(matcher: GymFixtures.matcher(inventory), exercises: GymFixtures.exercises, loggedCounts: logged,
                   preferences: preferences)
    }

    @Test func availableExercisesAreKeptAndLinked() {
        let result = adapter(GymFixtures.home).adapt([planned("b-kb-row", n: 1)])
        #expect(result == [.kept(planned("b-kb-row", n: 1), InventoryMatch(
            listingIds: [GymFixtures.id(1)], loadListingId: GymFixtures.id(1)))])
    }

    @Test func missingEquipmentSwapsToTheBestAvailableExerciseForTheSameTarget() {
        let result = adapter(GymFixtures.home).adapt([planned("a-db-curl", n: 1)])
        guard case let .swapped(plannedItem, replacement, match, missing) = result.first else {
            Issue.record("expected a swap, got \(result)")
            return
        }
        #expect(plannedItem.exerciseId == "a-db-curl")
        #expect(missing == ["dumbbells"])
        #expect(replacement.exerciseId == "a-kb-curl")
        #expect(match.loadListingId == GymFixtures.id(1))
    }

    @Test func twoItemsNeverSwapToTheSameExercise() {
        // At Home the push-up is the only chest exercise left, so the second item has nothing to swap to.
        let result = adapter(GymFixtures.home).adapt([planned("c-db-press", n: 1), planned("c-bb-bench", n: 3)])
        #expect(result.map(\.item.exerciseId) == ["c-pushup", "c-bb-bench"])
        #expect(result.last == .unavailable(planned("c-bb-bench", n: 3), missing: ["barbell"]))
    }

    @Test func replacementKeepsTheItemAndTargetsButNotThePlannedWeight() {
        guard case let .swapped(_, replacement, _, _) = adapter(GymFixtures.home).adapt([planned("a-db-curl", n: 2)]).first
        else {
            Issue.record("expected a swap")
            return
        }
        #expect(replacement.id == GymFixtures.id(102))
        #expect(replacement.sets == 4 && replacement.reps == 8 && replacement.repsMin == 6)
        #expect(replacement.supersetGroup == "A")
        #expect(replacement.weightKg == nil && replacement.weightSetAt == nil)
        #expect(replacement.incKg == RoutineExercise.defaults(exerciseId: "a-kb-curl", mode: .reps, barbell: false).incKg)
    }

    @Test func nothingSimilarAvailableIsUnavailable() {
        #expect(adapter(GymFixtures.home).adapt([planned("l-leg-press", n: 1)])
            == [.unavailable(planned("l-leg-press", n: 1), missing: ["leg-press"])])
    }

    @Test func unmappedExercisesStayAsPlanned() {
        #expect(adapter(GymFixtures.home).adapt([planned("x-shrug", n: 1)]) == [.unmapped(planned("x-shrug", n: 1))])
    }

    @Test func aReplacementIsNeverAlreadyInTheListSoItFallsBackToTheSameBodyPart() {
        // The kettlebell curl is already planned, so the dumbbell curl's swap moves on to the same body part.
        let result = adapter(GymFixtures.home).adapt([planned("a-kb-curl", n: 1), planned("a-db-curl", n: 2)])
        #expect(result.map(\.item.exerciseId) == ["a-kb-curl", "a-kb-skull"])
    }

    @Test func neverPreferencesAreNotUsedAsReplacements() {
        let never: [String: ExercisePreference] = ["a-kb-curl": .never, "a-kb-skull": .never]
        let result = adapter(GymFixtures.home, preferences: never).adapt([planned("a-db-curl", n: 1)])
        #expect(result == [.unavailable(planned("a-db-curl", n: 1), missing: ["dumbbells"])])
    }

    @Test func benchPressAtHomeFallsBackToABodyweightPushUp() {
        let result = adapter(GymFixtures.home).adapt([planned("c-bb-bench", n: 1)])
        #expect(result.first?.item.exerciseId == "c-pushup")
    }
}
