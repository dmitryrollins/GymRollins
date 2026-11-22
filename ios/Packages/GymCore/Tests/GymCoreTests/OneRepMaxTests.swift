import Testing
@testable import GymCore

@Suite struct OneRepMaxTests {
    @Test func epleyMatchesSampleBench() throws {
        // 19 Sep: 10 reps @ 150 lb (68.039 kg) -> 90.7 kg
        let e1rm = try #require(OneRepMax.estimate(weightKg: 68.039, reps: 10))
        #expect(abs(e1rm - 90.72) < 0.01)
        let prior = try #require(OneRepMax.estimate(weightKg: 68.039, reps: 6))
        #expect(abs(prior - 81.65) < 0.01)
    }

    @Test func otherFormulas() throws {
        #expect(abs(try #require(OneRepMax.estimate(weightKg: 100, reps: 5, formula: .brzycki)) - 112.5) < 0.01)
        #expect(abs(try #require(OneRepMax.estimate(weightKg: 100, reps: 10, formula: .lombardi)) - 125.89) < 0.01)
    }

    @Test func singleRepIsTheWeight() {
        #expect(OneRepMax.estimate(weightKg: 100, reps: 1) == 100)
    }

    @Test(arguments: [0, 13, 50])
    func rejectsRepsOutsideRange(reps: Int) {
        #expect(OneRepMax.estimate(weightKg: 100, reps: reps) == nil)
    }

    @Test func rejectsNonPositiveWeight() {
        #expect(OneRepMax.estimate(weightKg: 0, reps: 5) == nil)
    }
}
