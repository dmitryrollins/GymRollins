import Testing
@testable import GymCore

@Suite struct AvailableLoadsTests {
    private let bells = ListingLoads.fixed(kg: [24, 20])

    @Test func fixedSetPicksTheNearestWeight() {
        #expect(AvailableLoads.fit(weightKg: 21, reps: 10, to: bells) == FittedLoad(weightKg: 20, reps: 10))
        #expect(AvailableLoads.fit(weightKg: 23, reps: 10, to: bells) == FittedLoad(weightKg: 24, reps: 10))
        #expect(AvailableLoads.fit(weightKg: 18, reps: 10, to: bells) == FittedLoad(weightKg: 20, reps: 10))
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

    @Test func stackRoundsToTheNearestStepAndStopsAtItsMaximum() {
        #expect(AvailableLoads.fit(weightKg: 52, reps: 10, to: .stack(maxKg: 113, stepKg: 4.5))
            == FittedLoad(weightKg: 54, reps: 10))
        #expect(AvailableLoads.fit(weightKg: 112, reps: 10, to: .stack(maxKg: 112, stepKg: 4.5))
            == FittedLoad(weightKg: 112, reps: 10))
    }

    @Test func floatNoiseAtTheTopIsNotPastTheHeaviest() {
        #expect(AvailableLoads.fit(weightKg: 113.005, reps: 8, to: .stack(maxKg: 113, stepKg: nil))
            == FittedLoad(weightKg: 113, reps: 8), "never above the maximum, even without a step")
        #expect(AvailableLoads.fit(weightKg: 113.005, reps: 8, to: .stack(maxKg: 113, stepKg: 4.5))
            == FittedLoad(weightKg: 112.5, reps: 8))
        #expect(AvailableLoads.fit(weightKg: 113.3, reps: 8, to: .stack(maxKg: 113, stepKg: 4.5))
            == FittedLoad(weightKg: 113, reps: 10, atHeaviest: true))
        #expect(AvailableLoads.fit(weightKg: 24.005, reps: 8, to: bells) == FittedLoad(weightKg: 24, reps: 8))
        #expect(AvailableLoads.fit(weightKg: 24, reps: 8, to: bells) == FittedLoad(weightKg: 24, reps: 8))
    }

    @Test func aBellLoggedInPoundsIsNotPastTheHeaviest() {
        let fiftyThreeLb = UnitConverter.toKg(53, from: .lb) // 24.04 kg: the 24 kg bell
        #expect(AvailableLoads.fit(weightKg: fiftyThreeLb, reps: 8, to: .fixed(kg: [20, 24]))
            == FittedLoad(weightKg: 24, reps: 8), "the weight didn't rise, so the reps don't either")
        #expect(AvailableLoads.fit(weightKg: 25, reps: 8, to: .fixed(kg: [20, 24]))
            == FittedLoad(weightKg: 24, reps: 10, atHeaviest: true))
    }

    @Test func aStackLoggedInPoundsIsNotPastTheHeaviest() {
        let stack = ListingLoads.stack(maxKg: 40, stepKg: nil)
        let nearTop = UnitConverter.toKg(88.3, from: .lb) // 40.05 kg, a display-unit rounding above the stack
        #expect(AvailableLoads.fit(weightKg: nearTop, reps: 8, to: stack) == FittedLoad(weightKg: 40, reps: 8))
        #expect(AvailableLoads.fit(weightKg: 41, reps: 8, to: stack)
            == FittedLoad(weightKg: 40, reps: 10, atHeaviest: true))
    }

    @Test func stackWithNoPositiveMaximumChangesNothing() {
        #expect(AvailableLoads.fit(weightKg: 30, reps: 5, to: .stack(maxKg: 0, stepKg: 4.5))
            == FittedLoad(weightKg: 30, reps: 5))
        #expect(AvailableLoads.fit(weightKg: 30, reps: 5, to: .stack(maxKg: -10, stepKg: nil))
            == FittedLoad(weightKg: 30, reps: 5))
    }

    @Test func platesNoneEmptySetsAndNoSuggestionChangeNothing() {
        #expect(AvailableLoads.fit(weightKg: 61.2, reps: 5, to: .plates) == FittedLoad(weightKg: 61.2, reps: 5))
        #expect(AvailableLoads.fit(weightKg: 61.2, reps: 5, to: .none) == FittedLoad(weightKg: 61.2, reps: 5))
        #expect(AvailableLoads.fit(weightKg: 30, reps: 5, to: .fixed(kg: [])) == FittedLoad(weightKg: 30, reps: 5))
        #expect(AvailableLoads.fit(weightKg: 0, reps: 10, to: bells) == FittedLoad(weightKg: 0, reps: 10))
    }

    @Test func suggestionFittedToFixedSet() {
        let suggestion = Suggestion(weightKg: 30, reps: 8, sec: nil, reason: .success)
        #expect(suggestion.fitted(to: bells) == Suggestion(weightKg: 24, reps: 10, sec: nil, reason: .success))
    }

    @Test func suggestionFittedKeepsSecAndReason() {
        let timed = Suggestion(weightKg: 30, reps: 1, sec: 45, reason: .addTime)
        #expect(timed.fitted(to: bells) == Suggestion(weightKg: 24, reps: 1, sec: 45, reason: .addTime),
                "a timed exercise has no rep target to raise")
        let plates = Suggestion(weightKg: 61.2, reps: 8, sec: nil, reason: .noChange)
        #expect(plates.fitted(to: .plates) == plates)
    }

    // MARK: A fit never raises the weight by much (a crowd's typo must not become the user's load)

    @Test func aTypoOfAHugeWeightNeverRaisesTheSuggestion() {
        #expect(AvailableLoads.fit(weightKg: 20, reps: 8, to: .fixed(kg: [500])) == FittedLoad(weightKg: 20, reps: 8))
        #expect(AvailableLoads.fit(weightKg: 20, reps: 8, to: .fixed(kg: [50])) == FittedLoad(weightKg: 20, reps: 8))
        #expect(AvailableLoads.fit(weightKg: 20, reps: 8, to: .stack(maxKg: 200, stepKg: 50))
            == FittedLoad(weightKg: 20, reps: 8))
    }

    @Test func aGymWithOnlyAHeavyBellKeepsTheLighterSuggestion() {
        #expect(AvailableLoads.fit(weightKg: 16, reps: 10, to: .fixed(kg: [32])) == FittedLoad(weightKg: 16, reps: 10))
        #expect(AvailableLoads.fit(weightKg: 16, reps: 10, to: .fixed(kg: [24])) == FittedLoad(weightKg: 16, reps: 10))
    }

    @Test func aSmallRiseIsStillAllowed() {
        // 25 % of 16 is 4 kg: 12 and 20 are equally near, and the tie goes to the lighter one as it always did.
        #expect(AvailableLoads.fit(weightKg: 16, reps: 10, to: .fixed(kg: [12, 20])) == FittedLoad(weightKg: 12, reps: 10))
        #expect(AvailableLoads.fit(weightKg: 17, reps: 10, to: .fixed(kg: [12, 20])) == FittedLoad(weightKg: 20, reps: 10))
        #expect(AvailableLoads.fit(weightKg: 20, reps: 10, to: .fixed(kg: [25])) == FittedLoad(weightKg: 25, reps: 10),
                "+5 kg is within max(5 kg, 25 %)")
        #expect(AvailableLoads.fit(weightKg: 2.5, reps: 10, to: .fixed(kg: [5])) == FittedLoad(weightKg: 5, reps: 10))
    }

    @Test func aBiggerRiseUsesTheHeaviestLoadAtOrBelowTheWantedWeight() {
        // 30 wants 40-ish: the nearest is 40 (+10 > max(5, 7.5)); 25 is the heaviest not above 30.
        #expect(AvailableLoads.fit(weightKg: 30, reps: 10, to: .fixed(kg: [25, 40])) == FittedLoad(weightKg: 25, reps: 10))
        #expect(AvailableLoads.fit(weightKg: 76, reps: 10, to: .stack(maxKg: 200, stepKg: 50))
            == FittedLoad(weightKg: 50, reps: 10), "rounding 76 up to 100 would add 24 kg; the stack's 50 does not")
    }

    @Test func goingDownHasNoLimit() {
        #expect(AvailableLoads.fit(weightKg: 100, reps: 5, to: .fixed(kg: [10, 12])) == FittedLoad(weightKg: 12, reps: 7, atHeaviest: true))
        #expect(AvailableLoads.fit(weightKg: 100, reps: 5, to: .stack(maxKg: 40, stepKg: 5))
            == FittedLoad(weightKg: 40, reps: 7, atHeaviest: true))
    }
}
