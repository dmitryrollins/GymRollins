import Foundation
import Testing
@testable import GymCore

/// Progression, listing fits and warm-ups keep the pound number (plan 38): the rounder's result in lb is a pound
/// number; a carried weight copies its pound number, or in lb without one snaps to the nearest ½ lb.
@Suite struct PoundProgressionTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private func pounds(_ v: Double) -> PoundWeight { PoundWeight.entered(v, unit: .lb) }
    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }
    private let barbellLb = ProgressionEngine(rounder: .barbellLb, deloadPct: 0.05)
    private let dumbbellLb = ProgressionEngine(rounder: .dumbbellLb, deloadPct: 0.05)
    private let barbellKg = ProgressionEngine(rounder: .barbellKg, deloadPct: 0.05)

    private func target(_ kg: Double = 0, lb: Double? = nil, setAt: Date? = nil, fixedKg: Double? = nil,
                        fixedLb: Double? = nil) -> ProgressionTarget {
        ProgressionTarget(sets: 3, reps: 10, repsMin: 8, weightKg: kg, weightLb: lb, incKg: self.lb(5),
                          weightSetAt: setAt, fixedWeightKg: fixedKg, fixedWeightLb: fixedLb)
    }

    private func session(_ n: Int, kg: Double, lb: Double? = nil, reps: [Int], rir: [Double?] = []) -> SessionResult {
        SessionResult(date: day(n), weightKg: kg, weightLb: lb, reps: reps, rir: rir)
    }

    // MARK: The rounder's results

    @Test func theFirstSessionAndAPlannedWeightTakeTheRoundersPoundNumber() {
        #expect(barbellLb.suggest(policy: .double, target: target(20.3), history: []).weight == pounds(45))
        let none = barbellLb.suggest(policy: .double, target: target(0), history: [])
        #expect(none.weightKg == 0 && none.weightLb == nil, "nothing planned stays 0")
        let planned = barbellLb.suggest(policy: .double, target: target(lb(140), lb: 140, setAt: day(5)),
                                        history: [session(1, kg: lb(130), lb: 130, reps: [10, 10, 10])])
        #expect(planned.reason == .planned && planned.weight == pounds(140))
    }

    @Test func increasesAndADeloadTakeTheRoundersPoundNumber() {
        let top = [session(1, kg: 20.3, reps: [10, 10, 10])]
        #expect(barbellLb.suggest(policy: .double, target: target(), history: top).weight == pounds(50))
        #expect(barbellLb.suggest(policy: .linear, target: target(), history: top).weight == pounds(50))
        let amrap = [session(1, kg: lb(130), lb: 130, reps: [10, 10, 20])]
        let jump = barbellLb.suggest(policy: .greyskull, target: target(), history: amrap)
        #expect(jump.reason == .doubleJump && jump.weight == pounds(140))
        let misses = [session(2, kg: lb(130), lb: 130, reps: [7, 6, 6]), session(1, kg: lb(130), lb: 130, reps: [7, 6, 6])]
        let deload = barbellLb.suggest(policy: .double, target: target(), history: misses)
        #expect(deload.reason == .deload && deload.weight == pounds(120))
        let easy = [session(1, kg: lb(45), lb: 45, reps: [9, 9, 9], rir: [3, 3, 4])]
        let early = dumbbellLb.suggest(policy: .double, target: target(), history: easy)
        #expect(early.reason == .feltEasy && early.weight == pounds(50))
    }

    @Test func aPlanWeightTheRounderLeavesAsItWasKeepsItsPoundNumber() {
        let noGrid = ProgressionEngine(rounder: LoadRounder(unit: .lb, step: 0))
        let first = noGrid.suggest(policy: .double, target: target(lb(47.25), lb: 47.25), history: [])
        #expect(first.weight == PoundWeight.entered(47.25, unit: .lb))
        let planned = noGrid.suggest(policy: .double, target: target(lb(47.25), lb: 47.25, setAt: day(5)),
                                     history: [session(1, kg: lb(40), reps: [10, 10, 10])])
        #expect(planned.reason == .planned && planned.weightLb == 47.25)
    }

    @Test func theRoundersKgResultsHaveNoPoundNumber() {
        let top = [session(1, kg: lb(135), lb: 135, reps: [10, 10, 10])]
        let up = barbellKg.suggest(policy: .double, target: target(), history: top)
        #expect(up.reason == .topOfRange && up.weightLb == nil && up.weightKg == 62.5, "140 lb is 63.5 kg")
        #expect(barbellKg.suggest(policy: .double, target: target(lb(45), lb: 45), history: []).weightLb == nil)
    }

    // MARK: Carried weights

    @Test func aBodyweightOrTimedWeightCarriedInPoundsHasNoPoundNumber() {
        let off = barbellLb.suggest(policy: .off, target: target(), history: [session(1, kg: 0, reps: [10, 10, 10])])
        #expect(off.weight == PoundWeight(kg: 0, lb: nil))
        let time = dumbbellLb.suggest(policy: .time, mode: .time, target: target(),
                                      history: [SessionResult(date: day(1), weightKg: 0, reps: [1], secs: [30])])
        #expect(time.weight == PoundWeight(kg: 0, lb: nil))
        let fixed = barbellLb.suggest(policy: .double, target: target(fixedKg: 0), history: [])
        #expect(fixed.weight == PoundWeight(kg: 0, lb: nil))
    }

    @Test func keepGoingCopiesThePoundNumberOrSnapsInPounds() {
        let kept = barbellLb.suggest(policy: .double, target: target(),
                                     history: [session(1, kg: lb(47.5), lb: 47.5, reps: [10, 9, 8])])
        #expect(kept.reason == .keepGoing && kept.weight == pounds(47.5))
        let snapped = barbellLb.suggest(policy: .double, target: target(),
                                        history: [session(1, kg: 20.3, reps: [10, 9, 8])])
        #expect(snapped.reason == .keepGoing && snapped.weight == pounds(45), "20.3 kg (44.75 lb) doesn't repeat")
    }

    @Test func inKgACarriedWeightStaysAsItIs() {
        let raw = barbellKg.suggest(policy: .double, target: target(), history: [session(1, kg: 20.3, reps: [10, 9, 8])])
        #expect(raw.weight == PoundWeight(kg: 20.3, lb: nil))
        let copied = barbellKg.suggest(policy: .off, target: target(),
                                       history: [session(1, kg: lb(45), lb: 45, reps: [10, 10, 10])])
        #expect(copied.weight == pounds(45), "copying a weight copies both")
    }

    @Test func offCopiesThePoundNumberOrSnapsInPounds() {
        let kept = barbellLb.suggest(policy: .off, target: target(),
                                     history: [session(1, kg: lb(47.5), lb: 47.5, reps: [10, 10, 10])])
        #expect(kept.reason == .noChange && kept.weight == pounds(47.5))
        let snapped = barbellLb.suggest(policy: .off, target: target(), history: [session(1, kg: 21.4, reps: [10])])
        #expect(snapped.weight == pounds(47))
    }

    @Test func timedExercisesCopyThePoundNumberOrSnapInPounds() {
        let plank = ProgressionTarget(sets: 1, reps: 1, sec: 30, weightKg: 0, incKg: 0)
        let weighted = SessionResult(date: day(1), weightKg: lb(25), weightLb: 25, reps: [1], secs: [30])
        #expect(barbellLb.suggest(policy: .time, mode: .time, target: plank, history: [weighted]).weight == pounds(25))
        let old = SessionResult(date: day(1), weightKg: 11.2, reps: [1], secs: [20])
        let snapped = barbellLb.suggest(policy: .time, mode: .time, target: plank, history: [old])
        #expect(snapped.reason == .keepGoing && snapped.weight == pounds(24.5), "24.69 lb")
    }

    @Test func aFixedWeightCopiesItsPoundNumberOrSnapsInPounds() {
        let history = [session(1, kg: lb(130), lb: 130, reps: [10, 10, 10])]
        let fixed = barbellLb.suggest(policy: .double, target: target(fixedKg: lb(97.5), fixedLb: 97.5), history: history)
        #expect(fixed.reason == .noChange && fixed.weight == pounds(97.5))
        let snapped = barbellLb.suggest(policy: .double, target: target(fixedKg: 44), history: history)
        #expect(snapped.weight == pounds(97), "97.0 lb")
        #expect(barbellKg.suggest(policy: .double, target: target(fixedKg: 44), history: history).weight
            == PoundWeight(kg: 44, lb: nil))
    }

    // MARK: Listing fits

    @Test func aFitThatKeepsTheKgKeepsThePoundNumber() {
        let suggestion = Suggestion(weight: pounds(45), reps: 8, sec: nil, reason: .success)
        #expect(suggestion.fitted(to: .stack(maxKg: 100, stepKg: nil)).weight == pounds(45))
        #expect(suggestion.fitted(to: .plates).weight == pounds(45))
        #expect(AvailableLoads.fit(weightKg: lb(45), weightLb: 45, reps: 8, to: .none).weightLb == 45)
    }

    @Test func aFitToAListingMadeInPoundsTakesItsPoundNumber() {
        let suggestion = Suggestion(weight: pounds(50), reps: 8, sec: nil, reason: .success)
        let bells = ListingLoads.fixed(kg: [lb(35), lb(53), lb(62)])
        #expect(suggestion.fitted(to: bells).weight == PoundWeight(kg: lb(53), lb: 53))
        let stack = ListingLoads.stack(maxKg: lb(200), stepKg: lb(7.5))
        #expect(suggestion.fitted(to: stack).weightLb == 52.5)
        #expect(AvailableLoads.fit(weightKg: lb(50), weightLb: 50, reps: 8, to: bells).weightLb == 53)
    }

    @Test func aFitToAListingMadeInKgHasNoPoundNumber() {
        let suggestion = Suggestion(weight: pounds(50), reps: 8, sec: nil, reason: .success)
        let fitted = suggestion.fitted(to: .fixed(kg: [16, 24, 32]))
        #expect(fitted.weightKg == 24 && fitted.weightLb == nil)
    }

    // MARK: Warm-ups

    @Test func theRampWarmupTakesTheRoundersPoundNumberAndTheBarHasNone() {
        let lbSets = WarmupGenerator.sets(workingKg: lb(140), barKg: lb(45), rounder: .barbellLb)
        #expect(lbSets.map(\.weightLb) == [nil, 105])
        #expect(lbSets[1].weightKg == lb(105))
        let kgSets = WarmupGenerator.sets(workingKg: 100, barKg: 20, rounder: .barbellKg)
        #expect(kgSets.map(\.weightLb) == [nil, nil])
    }
}
