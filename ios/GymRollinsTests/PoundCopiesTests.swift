import Foundation
import GymCore
import GymData
import GymWatchLink
import Testing
@testable import GymRollins

/// Every copy of a set or plan weight copies its pound number with its kg (plan 38): Today's set edits, a day's own
/// copy of a workout, Replace on Today, and the Apple Watch.
@MainActor
@Suite struct PoundCopiesTests {
    typealias Fixture = WatchSessionActionTests

    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private func pounds(_ v: Double) -> PoundWeight { PoundWeight.entered(v, unit: .lb) }
    /// 47.25 lb stored a little under its kg (still the same weight).
    private let quarter = PoundWeight(kg: UnitConverter.toKg(47.25, from: .lb) - 0.009, lb: 47.25)
    private let clock = Fixture.Clock()

    // MARK: Today's set edits

    @Test func addingOrTogglingASetCopiesItsPoundNumber() {
        let sets = [WorkoutSet(weightKg: lb(45), weightLb: 45, reps: 10, warmup: true),
                    WorkoutSet(weightKg: lb(47.5), weightLb: 47.5, reps: 8)]
        let added = TodaySetEdits.adding(to: sets)
        #expect(added.last?.weight == pounds(47.5))
        let flipped = TodaySetEdits.togglingWarmup(added, index: 0)
        #expect(flipped[0].weight == pounds(45) && !flipped[0].warmup)
    }

    @Test func savingTodaysSetsToTheRoutineKeepsTheHeaviestSetsPoundNumber() {
        let item = RoutineExercise(exerciseId: "0313", sets: 3, reps: 10, weightKg: 20)
        let sets = [WorkoutSet(weightKg: lb(45), weightLb: 45, reps: 10),
                    WorkoutSet(weightKg: lb(47.5), weightLb: 47.5, reps: 10)]
        let saved = TodaySetEdits.routineItem(item, from: sets, at: Date(timeIntervalSince1970: 5))
        #expect(saved.weight == pounds(47.5))
        let kg = TodaySetEdits.routineItem(item, from: [WorkoutSet(weightKg: 22, reps: 10)], at: .now)
        #expect(kg.weight == PoundWeight(kg: 22, lb: nil))
    }

    // MARK: Plan copies

    @Test func aDaysOwnCopyKeepsThePoundNumber() {
        let push = Routine(name: "Push", exercises: [
            RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, weightKg: lb(140), weightLb: 140),
        ])
        #expect(WeekPlan.copy(of: push, for: 1).exercises[0].weight == pounds(140))
    }

    @Test func replaceKeepsBothPoundNumbers() {
        let item = RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, weightKg: lb(140), weightLb: 140)
            .with(fixedWeight: pounds(137.5))
        let replaced = item.withId(UUID())
        #expect(replaced.weight == pounds(140) && replaced.fixedWeight == pounds(137.5))
    }

    // MARK: Apple Watch

    @Test func theWatchShowsThePoundNumber() throws {
        let s = Fixture.makeSession(clock, entries: [
            WorkoutEntry(exerciseId: "0294", sets: [WorkoutSet(weightKg: quarter.kg, weightLb: quarter.lb, reps: 10)]),
        ])
        let next = try #require(WatchStateMapper.workout(session: s, now: clock.now, profile: Profile(unit: .lb),
                                                         exercise: Fixture.lookup, watchRecordsHealth: { _ in false })?.next)
        #expect(next.weight == 47.25)
        #expect(next.setDetail == "47.3 lb \u{00D7} 10")
    }

    @Test func aWeightSetOnTheWatchKeepsItsPoundNumber() {
        let planned = quarter
        #expect(WatchStateMapper.loggedWeight(weight: 47.25, unit: .lb, planned: planned) == planned, "unchanged")
        #expect(WatchStateMapper.loggedWeight(weight: 50, unit: .lb, planned: planned) == pounds(50))
        #expect(WatchStateMapper.loggedWeight(weight: 22.5, unit: .kg, planned: planned) == PoundWeight(kg: 22.5, lb: nil))
    }

    @Test func aSetLoggedOnTheWatchStoresThePoundNumber() {
        let s = Fixture.makeSession(clock)
        let entry = s.workout.entries[0]
        let handler = WatchCommandHandler(defaults: UserDefaults(suiteName: "pound-copies-\(UUID())")!, hooks: .init(
            session: { s }, exercise: Fixture.lookup, healthEnabled: { true }, startToday: { false },
            acceptClaim: { _ in }, recorded: { _ in }))
        let log = WatchCommand(issuedAt: clock.now, action: .logSet(workoutId: s.workout.id, entryId: entry.id,
                                                                   setId: entry.sets[0].id, weight: 137.5, unit: .lb,
                                                                   reps: 8))
        #expect(handler.handle(log) == .applied)
        #expect(s.workout.entries[0].sets[0].weight == pounds(137.5))
    }
}
