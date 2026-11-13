import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Starting a workout, swapping an exercise and logging a set keep the pound number (plan 38): a weight copied from
/// the plan, Today's edits, a suggestion or a swap target copies its pound number with its kg.
@MainActor
@Suite struct PoundSessionPlannerTests {
    typealias Fixture = WatchSessionActionTests

    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private func pounds(_ v: Double) -> PoundWeight { PoundWeight.entered(v, unit: .lb) }
    private let curl = Exercise(id: "0313", name: "dumbbell hammer curl", bodyPart: "upper arms",
                                equipment: "dumbbell", target: "biceps")
    /// 47.25 lb stored a little under its kg (still the same weight).
    private let quarter = PoundWeight(kg: UnitConverter.toKg(47.25, from: .lb) - 0.009, lb: 47.25)
    private let clock = Fixture.Clock()

    // MARK: Starting a workout

    @Test func setsEditedOnTodayStartWithTheirPoundNumbers() {
        let item = RoutineExercise(exerciseId: "0313", sets: 2, reps: 10)
        let sets = [WorkoutSet(weightKg: lb(47.5), weightLb: 47.5, reps: 10), WorkoutSet(weightKg: 20, reps: 8)]
        let entry = SessionPlanner.planned(item: item, sets: sets, exercise: curl)
        #expect(entry.sets.map(\.weight) == [pounds(47.5), PoundWeight(kg: 20, lb: nil)])
    }

    @Test func aPlanWeightReachesTheSuggestionWithItsPoundNumber() {
        // A dumbbell step of 0 is no grid: the plan weight reaches the workout as it is.
        let item = RoutineExercise(exerciseId: "0313", sets: 3, reps: 10, weightKg: quarter.kg, weightLb: quarter.lb)
        let suggestion = SessionPlanner.suggestion(for: item, policy: .double, profile: Profile(unit: .lb, dumbbellStepKg: 0),
                                                   exercise: curl, history: [])
        #expect(suggestion.weight == quarter)
    }

    @Test func aFixedWeightReachesTheSuggestionWithItsPoundNumber() {
        let item = RoutineExercise(exerciseId: "0313", sets: 3, reps: 10).with(fixedWeight: pounds(47.25))
        let suggestion = SessionPlanner.suggestion(for: item, policy: .double, profile: Profile(), exercise: curl,
                                                   history: [])
        #expect(suggestion.weight == pounds(47.25), "without it, lb would snap 47.25 to 47.5")
    }

    @Test func workingSetsTakeTheSuggestionsPoundNumber() {
        let item = RoutineExercise(exerciseId: "0313", sets: 3, reps: 10, repsMin: 8)
        let history = [SessionResult(date: .now, weightKg: lb(47.25), weightLb: 47.25, reps: [10, 9, 8])]
        let entry = SessionPlanner.entry(for: item, policy: .double, profile: Profile(), exercise: curl, history: history)
        #expect(entry.sets.map(\.weight) == Array(repeating: pounds(47.25), count: 3))
    }

    // MARK: Swapping

    @Test func aSwapMovesSetsToTheSuggestionWithItsPoundNumber() {
        let history = [SessionResult(date: .now, weightKg: lb(47.25), weightLb: 47.25, reps: [10, 9, 8])]
        let target = SessionPlanner.swapTarget(exercise: curl, profile: Profile(), history: history)
        #expect(target == .suggested(weight: pounds(47.25), loads: nil, timed: false))
        #expect(target.resolved(for: WorkoutSet(weightKg: 20, reps: 8)).weight == pounds(47.25))
    }

    @Test func aSwapThatKeepsOrFitsTheWeightKeepsItsPoundNumber() {
        let set = WorkoutSet(weightKg: lb(47.5), weightLb: 47.5, reps: 8)
        #expect(SwapTarget.keep.resolved(for: set) == ResolvedSet(weight: set.weight, reps: 8))
        #expect(SwapTarget.fit(.fixed(kg: [lb(47.5), 30])).resolved(for: set).weight == set.weight)
        let kgSet = WorkoutSet(weightKg: 20, reps: 8)
        #expect(SwapTarget.fit(.fixed(kg: [20, 24])).resolved(for: kgSet).weight == PoundWeight(kg: 20, lb: nil))
    }

    @Test func theSessionsSwapWritesThePoundNumber() {
        let s = Fixture.makeSession(clock)
        let bench = s.workout.entries[0].id
        s.swap(entryId: bench, to: "0294", multiplier: 2,
               target: .suggested(weight: pounds(47.25), loads: nil, timed: false))
        #expect(s.workout.entries[0].sets.map(\.weight) == [pounds(47.25), pounds(47.25)])
        s.swap(entryId: bench, to: "0025", multiplier: 1, target: .keep)
        #expect(s.workout.entries[0].sets.map(\.weight) == [pounds(47.25), pounds(47.25)], "keep keeps both")
    }

    // MARK: Logging

    @Test func loggingASetWritesItsPoundNumber() {
        let s = Fixture.makeSession(clock)
        let bench = s.workout.entries[0].id
        s.logNextSet(entryId: bench, weight: pounds(137.5), reps: 8)
        #expect(s.workout.entries[0].sets[0].weight == pounds(137.5))
        s.logNextSet(entryId: bench, weightKg: 62, reps: 8)
        #expect(s.workout.entries[0].sets[1].weight == PoundWeight(kg: 62, lb: nil))
    }
}
