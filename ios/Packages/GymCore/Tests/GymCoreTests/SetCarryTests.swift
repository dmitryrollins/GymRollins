import Foundation
import Testing
@testable import GymCore

@Suite struct SetCarryTests {
    private func set(_ kg: Double, done: Bool = false, warmup: Bool = false) -> WorkoutSet {
        WorkoutSet(weightKg: kg, reps: 10, done: done, warmup: warmup)
    }

    private func reps(_ n: Int, done: Bool = false, warmup: Bool = false) -> WorkoutSet {
        WorkoutSet(weightKg: 20, reps: n, done: done, warmup: warmup)
    }

    @Test func laterUnloggedSetsAtTheOldWeightFollow() {
        let sets = [set(20, done: true), set(20), set(20), set(20)]
        #expect(SetCarry.following(sets, edited: sets[1].id, fromKg: 20) == [sets[2].id, sets[3].id])
    }

    @Test func earlierAndLoggedSetsKeepTheirWeight() {
        let sets = [set(20), set(20), set(20, done: true), set(20)]
        #expect(SetCarry.following(sets, edited: sets[1].id, fromKg: 20) == [sets[3].id])
    }

    @Test func aSetChangedByHandStopsTheCarry() {
        let sets = [set(20), set(20), set(25), set(20)]
        #expect(SetCarry.following(sets, edited: sets[0].id, fromKg: 20) == [sets[1].id])
    }

    @Test func warmupsNeitherCarryNorReceive() {
        let warm = [set(10, warmup: true), set(10, warmup: true), set(20)]
        #expect(SetCarry.following(warm, edited: warm[0].id, fromKg: 10).isEmpty)
        let mixed = [set(20), set(20, warmup: true), set(20)]
        #expect(SetCarry.following(mixed, edited: mixed[0].id, fromKg: 20) == [mixed[2].id])
    }

    @Test func unknownSetOrMatchingWithinRoundingNoise() {
        let sets = [set(20.4), set(20.4000001)]
        #expect(SetCarry.following(sets, edited: UUID(), fromKg: 20.4).isEmpty)
        #expect(SetCarry.following(sets, edited: sets[0].id, fromKg: 20.4) == [sets[1].id])
    }

    @Test func laterSetsAtTheOldRepsFollow() {
        let sets = [reps(10), reps(10), reps(10)]
        #expect(SetCarry.following(sets, edited: sets[1].id, fromReps: 10) == [sets[2].id])
    }

    @Test func aDifferentRepsValueStopsTheCarry() {
        let sets = [reps(10), reps(10), reps(8)]
        #expect(SetCarry.following(sets, edited: sets[0].id, fromReps: 10) == [sets[1].id])
    }

    @Test func repsSkipLoggedAndWarmupSets() {
        let sets = [reps(10), reps(10, done: true), reps(10, warmup: true), reps(10)]
        #expect(SetCarry.following(sets, edited: sets[0].id, fromReps: 10) == [sets[3].id])
    }

    @Test func anEditedWarmupCarriesNoReps() {
        let sets = [reps(10, warmup: true), reps(10)]
        #expect(SetCarry.following(sets, edited: sets[0].id, fromReps: 10).isEmpty)
    }

    @Test func laterSetsAtTheOldSecondsFollow() {
        let timed = [30, 30, 45, 30].map { WorkoutSet(weightKg: 0, reps: 0, sec: $0) }
        #expect(SetCarry.following(timed, edited: timed[0].id, fromSec: 30) == [timed[1].id])
    }
}
