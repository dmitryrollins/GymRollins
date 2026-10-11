import Foundation
import Testing
@testable import GymCore

@Suite struct SetWeightCarryTests {
    private func set(_ kg: Double, done: Bool = false, warmup: Bool = false) -> WorkoutSet {
        WorkoutSet(weightKg: kg, reps: 10, done: done, warmup: warmup)
    }

    @Test func laterUnloggedSetsAtTheOldWeightFollow() {
        let sets = [set(20, done: true), set(20), set(20), set(20)]
        #expect(SetWeightCarry.following(sets, edited: sets[1].id, fromKg: 20) == [sets[2].id, sets[3].id])
    }

    @Test func earlierAndLoggedSetsKeepTheirWeight() {
        let sets = [set(20), set(20), set(20, done: true), set(20)]
        #expect(SetWeightCarry.following(sets, edited: sets[1].id, fromKg: 20) == [sets[3].id])
    }

    @Test func aSetChangedByHandStopsTheCarry() {
        let sets = [set(20), set(20), set(25), set(20)]
        #expect(SetWeightCarry.following(sets, edited: sets[0].id, fromKg: 20) == [sets[1].id])
    }

    @Test func warmupsNeitherCarryNorReceive() {
        let warm = [set(10, warmup: true), set(10, warmup: true), set(20)]
        #expect(SetWeightCarry.following(warm, edited: warm[0].id, fromKg: 10).isEmpty)
        let mixed = [set(20), set(20, warmup: true), set(20)]
        #expect(SetWeightCarry.following(mixed, edited: mixed[0].id, fromKg: 20) == [mixed[2].id])
    }

    @Test func unknownSetOrMatchingWithinRoundingNoise() {
        let sets = [set(20.4), set(20.4000001)]
        #expect(SetWeightCarry.following(sets, edited: UUID(), fromKg: 20.4).isEmpty)
        #expect(SetWeightCarry.following(sets, edited: sets[0].id, fromKg: 20.4) == [sets[1].id])
    }
}
