import Testing
@testable import GymCore

@Suite struct AvailableLoadsTests {
    private let bells = ListingLoads.fixed(kg: [24, 20])

    @Test func fixedSetPicksTheNearestWeight() {
        #expect(AvailableLoads.fit(weightKg: 21, reps: 10, to: bells) == FittedLoad(weightKg: 20, reps: 10))
        #expect(AvailableLoads.fit(weightKg: 23, reps: 10, to: bells) == FittedLoad(weightKg: 24, reps: 10))
        #expect(AvailableLoads.fit(weightKg: 10, reps: 10, to: bells) == FittedLoad(weightKg: 20, reps: 10))
    }

    @Test func fixedSetTiesGoToTheLighterWeight() {
        #expect(AvailableLoads.fit(weightKg: 22, reps: 8, to: bells) == FittedLoad(weightKg: 20, reps: 8))
    }

    @Test func pastTheHeaviestWeightKeepsItAndAddsReps() {
        #expect(AvailableLoads.fit(weightKg: 26, reps: 10, to: bells)
            == FittedLoad(weightKg: 24, reps: 12, atHeaviest: true))
        #expect(AvailableLoads.fit(weightKg: 120, reps: 8, to: .stack(maxKg: 113, stepKg: 4.5))
            == FittedLoad(weightKg: 113, reps: 10, atHeaviest: true))
    }

    @Test func stackSnapsToItsStep() {
        #expect(AvailableLoads.fit(weightKg: 50, reps: 10, to: .stack(maxKg: 113, stepKg: 4.5))
            == FittedLoad(weightKg: 49.5, reps: 10))
        #expect(AvailableLoads.fit(weightKg: 51, reps: 10, to: .stack(maxKg: 113, stepKg: nil))
            == FittedLoad(weightKg: 51, reps: 10))
        #expect(AvailableLoads.fit(weightKg: 1, reps: 10, to: .stack(maxKg: 113, stepKg: 4.5))
            == FittedLoad(weightKg: 4.5, reps: 10), "never below one plate of the stack")
    }

    @Test func platesNoneEmptySetsAndNoSuggestionChangeNothing() {
        #expect(AvailableLoads.fit(weightKg: 61.2, reps: 5, to: .plates) == FittedLoad(weightKg: 61.2, reps: 5))
        #expect(AvailableLoads.fit(weightKg: 61.2, reps: 5, to: .none) == FittedLoad(weightKg: 61.2, reps: 5))
        #expect(AvailableLoads.fit(weightKg: 30, reps: 5, to: .fixed(kg: [])) == FittedLoad(weightKg: 30, reps: 5))
        #expect(AvailableLoads.fit(weightKg: 0, reps: 10, to: bells) == FittedLoad(weightKg: 0, reps: 10))
    }
}
