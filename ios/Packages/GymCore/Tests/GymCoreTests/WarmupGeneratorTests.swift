import Testing
@testable import GymCore

@Suite struct WarmupGeneratorTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private func inLb(_ kg: Double) -> Double { (UnitConverter.fromKg(kg, to: .lb) * 100).rounded() / 100 }

    @Test func heavyWorkingSetGetsTwoWarmups() {
        // Mockup: 140 lb working -> bar x10, 105 x5
        let sets = WarmupGenerator.sets(workingKg: lb(140), barKg: lb(45), rounder: .barbellLb)
        #expect(sets.map { inLb($0.weightKg) } == [45, 105])
        #expect(sets.map(\.reps) == [10, 5])
        #expect(sets.allSatisfy { $0.warmup && !$0.done })
    }

    @Test func lightWorkingSetGetsBarOnly() {
        let sets = WarmupGenerator.sets(workingKg: lb(60), barKg: lb(45), rounder: .barbellLb)
        #expect(sets.map { inLb($0.weightKg) } == [45])
    }

    @Test func workingAtOrBelowBarGetsNone() {
        #expect(WarmupGenerator.sets(workingKg: lb(45), barKg: lb(45), rounder: .barbellLb).isEmpty)
    }

    @Test func barbellKgHeavyWorkingSetGetsTwoWarmups() {
        let sets = WarmupGenerator.sets(workingKg: 100, barKg: 20, rounder: .barbellKg)
        #expect(sets.map(\.weightKg) == [20, 75])
        #expect(sets.map(\.reps) == [10, 5])
    }
}
