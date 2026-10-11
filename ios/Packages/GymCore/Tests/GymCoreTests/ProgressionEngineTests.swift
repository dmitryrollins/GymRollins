import Foundation
import Testing
@testable import GymCore

@Suite struct ProgressionEngineTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private func inLb(_ kg: Double) -> Double { (UnitConverter.fromKg(kg, to: .lb) * 100).rounded() / 100 }
    private let engine = ProgressionEngine(rounder: .barbellLb, deloadPct: 0.05)
    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }
    private func session(_ n: Int, _ w: Double, _ reps: [Int]) -> SessionResult {
        SessionResult(date: day(n), weightKg: lb(w), reps: reps)
    }
    private var bench: ProgressionTarget {
        ProgressionTarget(sets: 3, reps: 10, repsMin: 8, weightKg: lb(130), incKg: lb(5))
    }

    // MARK: Mode-compatible policies (Codex P2)

    @Test func timedExerciseUnderALoadPolicyKeepsADurationTarget() {
        let plank = ProgressionTarget(sets: 3, reps: 1, sec: 30, weightKg: 0, incKg: 0)
        let done = SessionResult(date: day(1), weightKg: 0, reps: [1, 1, 1], secs: [30, 30, 30])
        for policy in [ProgressionPolicy.double, .linear, .greyskull] {
            let s = engine.suggest(policy: policy, mode: .time, target: plank, history: [done])
            #expect(s.sec == 35 && s.reason == .addTime && s.weightKg == 0)
        }
        let missed = SessionResult(date: day(1), weightKg: 0, reps: [1, 1, 1], secs: [20, 20, 20])
        let twoMisses = [missed, SessionResult(date: day(0), weightKg: 0, reps: [1, 1, 1], secs: [20, 20, 20])]
        #expect(engine.suggest(policy: .double, mode: .time, target: plank, history: twoMisses).sec == 30)
    }

    @Test func cardioKeepsItsDurationAndLoad() {
        let run = ProgressionTarget(sets: 1, reps: 1, sec: 1_200, weightKg: 0, incKg: lb(5))
        let last = SessionResult(date: day(1), weightKg: 0, reps: [1], secs: [1_200])
        let s = engine.suggest(policy: .double, mode: .cardio, target: run, history: [last])
        #expect(s.sec == 1_200 && s.weightKg == 0 && s.reps == 1)
    }

    @Test func policyEffectiveForMode() {
        #expect(ProgressionPolicy.double.effective(for: .time) == .time)
        #expect(ProgressionPolicy.off.effective(for: .time) == .off)
        #expect(ProgressionPolicy.linear.effective(for: .cardio) == .off)
        #expect(ProgressionPolicy.greyskull.effective(for: .reps) == .greyskull)
        #expect(RoutineExercise.defaults(exerciseId: "p", mode: .time, barbell: false).policy == .time)
        #expect(RoutineExercise.defaults(exerciseId: "r", mode: .cardio, barbell: false).policy == .off)
        #expect(RoutineExercise.defaults(exerciseId: "b", mode: .reps, barbell: true).policy == nil)
    }

    @Test func firstSessionUsesTarget() {
        let s = engine.suggest(policy: .double, target: bench, history: [])
        #expect(inLb(s.weightKg) == 130)
        #expect(s.reps == 8)
        #expect(s.reason == .firstSession)
    }

    @Test func doubleProgressionTopOfRangeAddsIncrement() {
        let s = engine.suggest(policy: .double, target: bench, history: [session(2, 130, [10, 10, 10])])
        #expect(inLb(s.weightKg) == 135)
        #expect(s.reps == 8)
        #expect(s.reason == .topOfRange)
    }

    @Test func doubleProgressionNotYetKeepsWeight() {
        let s = engine.suggest(policy: .double, target: bench, history: [session(2, 130, [10, 9, 8])])
        #expect(inLb(s.weightKg) == 130)
        #expect(s.reps == 10)
        #expect(s.reason == .keepGoing)
    }

    @Test func twoMissesAtSameWeightDeloadFivePercent() {
        // Owner's shoulder press: stuck at 70 lb -> 65 lb
        let press = ProgressionTarget(sets: 3, reps: 12, repsMin: 10, weightKg: lb(70), incKg: lb(5))
        let s = engine.suggest(policy: .double, target: press,
                               history: [session(5, 70, [8, 10, 8]), session(2, 70, [10, 10, 9])])
        #expect(inLb(s.weightKg) == 65)
        #expect(s.reps == 10)
        #expect(s.reason == .deload)
    }

    @Test func missesAtDifferentWeightsDoNotDeload() {
        let press = ProgressionTarget(sets: 3, reps: 12, repsMin: 10, weightKg: lb(70), incKg: lb(5))
        let s = engine.suggest(policy: .double, target: press,
                               history: [session(5, 70, [8, 10, 8]), session(2, 65, [9, 10, 9])])
        #expect(s.reason == .keepGoing)
    }

    @Test func linearSuccessAddsIncrementKeepsReps() {
        let t = ProgressionTarget(sets: 3, reps: 5, weightKg: lb(135), incKg: lb(5))
        let s = engine.suggest(policy: .linear, target: t, history: [session(2, 135, [5, 5, 5])])
        #expect(inLb(s.weightKg) == 140)
        #expect(s.reps == 5)
        #expect(s.reason == .success)
    }

    @Test func greyskullDoubleJumpOnBigAmrap() {
        let t = ProgressionTarget(sets: 3, reps: 5, weightKg: lb(135), incKg: lb(5))
        let s = engine.suggest(policy: .greyskull, target: t, history: [session(2, 135, [5, 5, 10])])
        #expect(inLb(s.weightKg) == 145)
        #expect(s.reason == .doubleJump)
    }

    @Test func timePolicyAddsFiveSeconds() {
        let t = ProgressionTarget(sets: 3, reps: 1, sec: 30, weightKg: 0, incKg: 0)
        let hit = engine.suggest(policy: .time, target: t,
                                 history: [SessionResult(date: day(1), weightKg: 0, reps: [], secs: [30, 31, 30])])
        #expect(hit.sec == 35)
        #expect(hit.reason == .addTime)
        let miss = engine.suggest(policy: .time, target: t,
                                  history: [SessionResult(date: day(1), weightKg: 0, reps: [], secs: [30, 20])])
        #expect(miss.sec == 30)
        #expect(miss.reason == .keepGoing)
    }

    @Test func timePolicyStepsGoalUpAcrossHistoryThenAddsFiveOnNewHit() {
        // 30s target hit -> goal becomes 35; newest session also hits 35 -> goal becomes 40.
        let t = ProgressionTarget(sets: 3, reps: 1, sec: 30, weightKg: 0, incKg: 0)
        let older = SessionResult(date: day(1), weightKg: 0, reps: [], secs: [30, 31, 30])
        let newest = SessionResult(date: day(2), weightKg: 0, reps: [], secs: [35, 37, 35])
        let s = engine.suggest(policy: .time, target: t, history: [newest, older])
        #expect(s.sec == 40)
        #expect(s.reason == .addTime)
    }

    @Test func timePolicyMissAtRaisedGoalStaysAtGoal() {
        // 30s target hit -> goal becomes 35; newest session misses at 35 -> stays at 35.
        let t = ProgressionTarget(sets: 3, reps: 1, sec: 30, weightKg: 0, incKg: 0)
        let older = SessionResult(date: day(1), weightKg: 0, reps: [], secs: [30, 31, 30])
        let newest = SessionResult(date: day(2), weightKg: 0, reps: [], secs: [35, 34, 35])
        let s = engine.suggest(policy: .time, target: t, history: [newest, older])
        #expect(s.sec == 35)
        #expect(s.reason == .keepGoing)
    }

    @Test func offRepeatsLastWeight() {
        let s = engine.suggest(policy: .off, target: bench, history: [session(2, 125, [10, 10, 10])])
        #expect(inLb(s.weightKg) == 125)
        #expect(s.reason == .noChange)
    }

    @Test func plannedWeightAboveLastWins() {
        // Claude raised the plan to 140 lb on day 3, after the last session (day 2) at 130 lb.
        let t = ProgressionTarget(sets: 3, reps: 8, repsMin: 8, weightKg: lb(140), incKg: lb(5), weightSetAt: day(3))
        let s = engine.suggest(policy: .double, target: t, history: [session(2, 130, [10, 10, 10])])
        #expect(inLb(s.weightKg) == 140)
        #expect(s.reason == .planned)
    }

    @Test func plannedOverrideIgnoredWhenWeightSetAtIsNil() {
        // Routine target is still 70 lb from before a deload; the deload itself is the last session at 65 lb.
        // With no weightSetAt, the unchanged target must not pull the suggestion back up to 70.
        let press = ProgressionTarget(sets: 3, reps: 12, repsMin: 10, weightKg: lb(70), incKg: lb(5))
        let s = engine.suggest(policy: .double, target: press, history: [session(3, 65, [10, 10, 10])])
        #expect(inLb(s.weightKg) == 65)
        #expect(s.reason == .keepGoing)
    }

    @Test func plannedOverrideIgnoredWhenWeightSetAtIsOlderThanLastSession() {
        let press = ProgressionTarget(sets: 3, reps: 12, repsMin: 10, weightKg: lb(70), incKg: lb(5),
                                      weightSetAt: day(1))
        let s = engine.suggest(policy: .double, target: press, history: [session(3, 65, [10, 10, 10])])
        #expect(inLb(s.weightKg) == 65)
        #expect(s.reason == .keepGoing)
    }

    @Test func plannedOverrideAppliesWhenWeightSetAtIsAfterLastSession() {
        let press = ProgressionTarget(sets: 3, reps: 12, repsMin: 10, weightKg: lb(70), incKg: lb(5),
                                      weightSetAt: day(4))
        let s = engine.suggest(policy: .double, target: press, history: [session(3, 65, [10, 10, 10])])
        #expect(inLb(s.weightKg) == 70)
        #expect(s.reason == .planned)
    }

    @Test func plannedReductionAfterLastSessionWins() {
        // Claude lowered bench to 115 lb on day 3, after a day-2 session that hit the top of the range at 130 lb:
        // the next workout uses the planned 115, not 135 from progression.
        let t = ProgressionTarget(sets: 3, reps: 10, repsMin: 8, weightKg: lb(115), incKg: lb(5), weightSetAt: day(3))
        let s = engine.suggest(policy: .double, target: t, history: [session(2, 130, [10, 10, 10])])
        #expect(inLb(s.weightKg) == 115)
        #expect(s.reps == 8)
        #expect(s.reason == .planned)
    }

    @Test func plannedSameWeightDoesNotSkipProgression() {
        let t = ProgressionTarget(sets: 3, reps: 10, repsMin: 8, weightKg: lb(130), incKg: lb(5), weightSetAt: day(3))
        let s = engine.suggest(policy: .double, target: t, history: [session(2, 130, [10, 10, 10])])
        #expect(inLb(s.weightKg) == 135)
        #expect(s.reason == .topOfRange)
    }

    @Test func dumbbellLbIncrementRounds() {
        let dumbbellEngine = ProgressionEngine(rounder: .dumbbellLb)
        let t = ProgressionTarget(sets: 3, reps: 10, weightKg: lb(25), incKg: lb(2.5))
        let s = dumbbellEngine.suggest(policy: .linear, target: t, history: [session(2, 25, [10, 10, 10])])
        #expect(inLb(s.weightKg) == 27.5)
        #expect(s.reason == .success)
    }

    @Test func barbellKgIncrementRounds() {
        let kgEngine = ProgressionEngine(rounder: .barbellKg)
        let t = ProgressionTarget(sets: 3, reps: 5, weightKg: 60, incKg: 2.5)
        let history = [SessionResult(date: day(2), weightKg: 60, reps: [5, 5, 5])]
        let s = kgEngine.suggest(policy: .linear, target: t, history: history)
        #expect(s.weightKg == 62.5)
        #expect(s.reason == .success)
    }

    @Test func firstSessionRoundsTargetWeight() {
        let t = ProgressionTarget(sets: 3, reps: 8, weightKg: 60, incKg: lb(5))
        let s = engine.suggest(policy: .double, target: t, history: [])
        #expect(inLb(s.weightKg) == 130)
        #expect(s.reason == .firstSession)
    }

    @Test func firstSessionZeroWeightStaysZero() {
        let t = ProgressionTarget(sets: 3, reps: 8, weightKg: 0, incKg: 0)
        let s = engine.suggest(policy: .double, target: t, history: [])
        #expect(s.weightKg == 0)
        #expect(s.reason == .firstSession)
    }

    @Test func plannedOverrideRoundsTargetWeight() {
        let t = ProgressionTarget(sets: 3, reps: 8, weightKg: 60, incKg: lb(5), weightSetAt: day(4))
        let s = engine.suggest(policy: .double, target: t, history: [session(3, 50, [8, 8, 8])])
        #expect(inLb(s.weightKg) == 130)
        #expect(s.reason == .planned)
    }

    @Test func greyskullSuccessWithoutDoubleJumpAmrap() {
        let t = ProgressionTarget(sets: 3, reps: 5, weightKg: lb(135), incKg: lb(5))
        let s = engine.suggest(policy: .greyskull, target: t, history: [session(2, 135, [5, 5, 6])])
        #expect(inLb(s.weightKg) == 140)
        #expect(s.reason == .success)
    }
}
