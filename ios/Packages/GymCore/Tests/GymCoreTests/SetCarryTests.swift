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

    @Test func laterUnloggedSetsWithTheSameValueFollow() {
        let sets = [set(20, done: true), set(20), set(20), set(20)]
        #expect(SetCarry.following(sets, edited: sets[1].id, value: \.weightKg) == [sets[2].id, sets[3].id])
    }

    @Test func earlierAndLoggedSetsAreSkipped() {
        let sets = [set(20), set(20), set(20, done: true), set(20)]
        #expect(SetCarry.following(sets, edited: sets[1].id, value: \.weightKg) == [sets[3].id])
    }

    @Test func theFirstDifferentValueStopsTheCarry() {
        let sets = [reps(10), reps(10), reps(8), reps(10)]
        #expect(SetCarry.following(sets, edited: sets[0].id, value: \.reps) == [sets[1].id])
    }

    @Test func loggedAndWarmupSetsInBetweenAreSkipped() {
        let sets = [reps(10), reps(10, done: true), reps(10, warmup: true), reps(10)]
        #expect(SetCarry.following(sets, edited: sets[0].id, value: \.reps) == [sets[3].id])
        let different = [reps(10), reps(8, done: true), reps(6, warmup: true), reps(10)]
        #expect(SetCarry.following(different, edited: different[0].id, value: \.reps) == [different[3].id],
                "a skipped set's value doesn't stop the carry")
    }

    @Test func anEditedWarmupCarriesNothing() {
        let sets = [reps(10, warmup: true), reps(10), reps(10)]
        #expect(SetCarry.following(sets, edited: sets[0].id, value: \.reps).isEmpty)
    }

    @Test func anEditedLoggedSetCarriesNothing() {
        let sets = [reps(10, done: true), reps(10), reps(10)]
        #expect(SetCarry.following(sets, edited: sets[0].id, value: \.reps).isEmpty)
    }

    @Test func anUnknownSetCarriesNothing() {
        let sets = [set(20), set(20)]
        #expect(SetCarry.following(sets, edited: UUID(), value: \.weightKg).isEmpty)
    }

    @Test func optionalValuesCompareToo() {
        let timed = [30, 30, 45, 30].map { WorkoutSet(weightKg: 0, reps: 0, sec: $0) }
        #expect(SetCarry.following(timed, edited: timed[0].id, value: \.sec) == [timed[1].id])
    }
}
