import Foundation
import Testing
@testable import GymCore

/// How logged reps in reserve (RIR) nudges the load policies. Without RIR the engine is unchanged
/// (`ProgressionEngineTests`).
@Suite struct ProgressionEffortTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private func inLb(_ kg: Double) -> Double { (UnitConverter.fromKg(kg, to: .lb) * 100).rounded() / 100 }
    private let engine = ProgressionEngine(rounder: .barbellLb, deloadPct: 0.05)
    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }
    private func session(_ n: Int, _ w: Double, _ reps: [Int], rir: [Double?] = []) -> SessionResult {
        SessionResult(date: day(n), weightKg: lb(w), reps: reps, rir: rir)
    }
    /// 3 × 8–10, +5 lb.
    private var bench: ProgressionTarget {
        ProgressionTarget(sets: 3, reps: 10, repsMin: 8, weightKg: lb(130), incKg: lb(5))
    }

    @Test func easySetsInTheRangeAddTheIncrementEarly() {
        let s = engine.suggest(policy: .double, target: bench, history: [session(2, 130, [10, 9, 8], rir: [3, 3, 4])])
        #expect(inLb(s.weightKg) == 135)
        #expect(s.reps == 8)
        #expect(s.reason == .feltEasy)
    }

    @Test func averageBelowThreeHolds() {
        let s = engine.suggest(policy: .double, target: bench, history: [session(2, 130, [10, 9, 8], rir: [3, 3, 2])])
        #expect(inLb(s.weightKg) == 130)
        #expect(s.reason == .keepGoing)
    }

    @Test func unratedSetsAreLeftOutOfTheAverage() {
        let s = engine.suggest(policy: .double, target: bench, history: [session(2, 130, [10, 9, 8], rir: [nil, 4, nil])])
        #expect(s.reason == .feltEasy)
    }

    @Test func aSetToFailureShortOfTheTargetHoldsEvenWhenTheAverageIsEasy() {
        let s = engine.suggest(policy: .double, target: bench, history: [session(2, 130, [10, 9, 8], rir: [5, 4, 0])])
        #expect(inLb(s.weightKg) == 130)
        #expect(s.reason == .keepGoing)
    }

    @Test func easyButBelowTheRangeHolds() {
        let s = engine.suggest(policy: .double, target: bench, history: [session(2, 130, [10, 9, 7], rir: [4, 4, 4])])
        #expect(inLb(s.weightKg) == 130)
        #expect(s.reason == .keepGoing)
        let fewerSets = engine.suggest(policy: .double, target: bench, history: [session(2, 130, [10, 9], rir: [4, 4])])
        #expect(fewerSets.reason == .keepGoing)
    }

    @Test func failureNeverDecreasesOnItsOwn() {
        let s = engine.suggest(policy: .double, target: bench, history: [session(2, 130, [10, 9, 8], rir: [0, 0, 0])])
        #expect(inLb(s.weightKg) == 130)
        #expect(s.reason == .keepGoing)
    }

    @Test func topOfTheRangeStillProgressesAtFailure() {
        let s = engine.suggest(policy: .double, target: bench, history: [session(2, 130, [10, 10, 10], rir: [0, 0, 0])])
        #expect(inLb(s.weightKg) == 135)
        #expect(s.reason == .topOfRange)
    }

    @Test func easyNeverStepsMoreThanTheIncrement() {
        let topped = engine.suggest(policy: .double, target: bench, history: [session(2, 130, [10, 10, 10], rir: [5, 5, 5])])
        #expect(inLb(topped.weightKg) == 135)
        #expect(topped.reason == .topOfRange)
        // 2.5 lb on a 5 lb barbell grid: the normal rule rounds to the nearest load, but an early bump only goes up
        // when a whole increment fits, so it holds.
        let small = ProgressionTarget(sets: 3, reps: 10, repsMin: 8, weightKg: lb(130), incKg: lb(2.5))
        let s = engine.suggest(policy: .double, target: small, history: [session(2, 130, [10, 9, 8], rir: [4, 4, 4])])
        #expect(inLb(s.weightKg) == 130)
        #expect(s.reason == .keepGoing)
    }

    @Test func linearWithARangeUsesItsTopRepsAfterAnEasyBump() {
        let fives = ProgressionTarget(sets: 3, reps: 5, repsMin: 3, weightKg: lb(185), incKg: lb(10))
        let s = engine.suggest(policy: .linear, target: fives, history: [session(2, 185, [5, 4, 4], rir: [3, 3, 3])])
        #expect(inLb(s.weightKg) == 195)
        #expect(s.reps == 5)
        #expect(s.reason == .feltEasy)
        let noRange = ProgressionTarget(sets: 3, reps: 5, weightKg: lb(185), incKg: lb(10))
        let missed = engine.suggest(policy: .linear, target: noRange, history: [session(2, 185, [5, 5, 4], rir: [4, 4, 4])])
        #expect(missed.reason == .keepGoing)
    }

    @Test func deloadAndPlannedWeightStillWin() {
        let press = ProgressionTarget(sets: 3, reps: 12, repsMin: 10, weightKg: lb(70), incKg: lb(5))
        let deload = engine.suggest(policy: .double, target: press, history: [
            session(5, 70, [8, 10, 8], rir: [4, 4, 4]), session(2, 70, [10, 10, 9]),
        ])
        #expect(deload.reason == .deload)
        let planned = ProgressionTarget(sets: 3, reps: 10, repsMin: 8, weightKg: lb(120), incKg: lb(5),
                                        weightSetAt: day(3))
        let s = engine.suggest(policy: .double, target: planned, history: [session(2, 130, [10, 9, 8], rir: [4, 4, 4])])
        #expect(s.reason == .planned)
    }

    @Test func offAndTimePoliciesIgnoreEffort() {
        let off = engine.suggest(policy: .off, target: bench, history: [session(2, 130, [10, 9, 8], rir: [4, 4, 4])])
        #expect(off.reason == .noChange)
        let plank = ProgressionTarget(sets: 3, reps: 1, sec: 30, weightKg: 0, incKg: 0)
        let held = SessionResult(date: day(1), weightKg: 0, reps: [1, 1, 1], secs: [20, 20, 20], rir: [4, 4, 4])
        #expect(engine.suggest(policy: .time, mode: .time, target: plank, history: [held]).reason == .keepGoing)
    }

    @Test func withoutRirEverySuggestionIsUnchanged() {
        let histories: [[SessionResult]] = [
            [session(2, 130, [10, 9, 8])], [session(2, 130, [10, 10, 10])], [session(2, 130, [10, 9, 7])],
            [session(5, 130, [8, 9, 8]), session(2, 130, [9, 9, 9])],
        ]
        for history in histories {
            let unrated = history.map { SessionResult(date: $0.date, weightKg: $0.weightKg, reps: $0.reps,
                                                      rir: $0.reps.map { _ in nil }) }
            for policy in [ProgressionPolicy.double, .linear, .greyskull] {
                #expect(engine.suggest(policy: policy, target: bench, history: unrated)
                        == engine.suggest(policy: policy, target: bench, history: history))
            }
        }
    }
}
