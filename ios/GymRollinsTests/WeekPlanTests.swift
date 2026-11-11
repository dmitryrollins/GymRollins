import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// The week as the plan (owner, 2026-11-10): day names, which days a workout is on, and "Only Monday", a copy of the
/// workout that takes over that one day.
@MainActor
@Suite struct WeekPlanTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    @Test func dayNamesRunMondayToSunday() {
        #expect(WeekPlan.dayName(1, calendar: calendar) == "Monday")
        #expect(WeekPlan.dayName(7, calendar: calendar) == "Sunday")
        #expect(WeekPlan.shortDayName(6, calendar: calendar) == "Sat")
        #expect(WeekPlan.dayList([6, 1], calendar: calendar) == "Monday and Saturday")
    }

    @Test func aWorkoutsDaysComeMondayFirst() {
        let push = UUID(), pull = UUID()
        let schedule = WeekSchedule(days: [6: push, 1: push, 3: pull])
        #expect(WeekPlan.weekdays(of: push, in: schedule) == [1, 6])
        #expect(WeekPlan.weekdays(of: UUID(), in: schedule).isEmpty)
    }

    @Test func theExerciseLineNamesThreeAndCountsTheRest() {
        #expect(WeekPlan.exerciseLine(["Bench", "Dips", "Curl", "Fly", "Raise"]) == "Bench \u{00B7} Dips \u{00B7} Curl +2")
        #expect(WeekPlan.exerciseLine(["Bench"]) == "Bench")
        #expect(WeekPlan.exerciseLine([]) == "")
    }

    @Test func theCopyIsANewWorkoutForThatDay() {
        let item = RoutineExercise(exerciseId: "0025", sets: 4, reps: 8, weightKg: 60, supersetGroup: "A",
                                   weightSetAt: Date(timeIntervalSince1970: 1))
        let push = Routine(name: "Push + Arms", emoji: "💪", policy: .linear, exercises: [item])
        let copy = WeekPlan.copy(of: push, for: 1, calendar: calendar)
        #expect(copy.id != push.id)
        #expect(copy.name == "Push + Arms (Mon)")
        #expect(copy.emoji == "💪")
        #expect(copy.policy == .linear)
        #expect(!copy.paused)
        #expect(copy.exercises.map(\.id) != push.exercises.map(\.id), "an item id belongs to one workout")
        #expect(copy.exercises.map(\.exerciseId) == ["0025"])
        #expect(copy.exercises[0].sets == 4)
        #expect(copy.exercises[0].weightKg == 60)
        #expect(copy.exercises[0].supersetGroup == "A")
        #expect(copy.exercises[0].weightSetAt == item.weightSetAt)
    }

    @Test func theCopysNameStaysWithinTheLimit() {
        let long = Routine(name: String(repeating: "x", count: DomainLimits.routineNameMax), exercises: [])
        let copy = WeekPlan.copy(of: long, for: 3, calendar: calendar)
        #expect(copy.name.count == DomainLimits.routineNameMax)
        #expect(copy.name.hasSuffix(" (Wed)"))
    }

    // MARK: On the store (seed: Push + Arms on Monday and Saturday, Pull on Wednesday)

    private func makeEnv() throws -> AppEnvironment {
        let defaults = try #require(UserDefaults(suiteName: "WeekPlanTests.\(UUID())"))
        return try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]),
                                  defaults: defaults)
    }

    private func push(_ env: AppEnvironment) throws -> Routine {
        try #require(try env.routines.all().first { $0.name == "Push + Arms" })
    }

    @Test func theOtherDaysOfAWorkout() throws {
        let env = try makeEnv(), push = try push(env)
        #expect(try env.otherDays(of: push.id, besides: 6) == [1])
        #expect(try env.otherDays(of: push.id, besides: 2) == [1, 6])
    }

    @Test func savingForEveryDayEditsTheWorkout() throws {
        let env = try makeEnv(), push = try push(env)
        let edited = push.with(exercises: Array(push.exercises.dropFirst()))
        let saved = try env.saveWorkout(edited)
        #expect(saved.id == push.id)
        #expect(try env.routines.routine(push.id)?.exercises.count == push.exercises.count - 1)
        #expect(try env.routines.schedule().days[1] == push.id)
    }

    @Test func savingForOneDayPutsACopyOnThatDayOnly() throws {
        let env = try makeEnv(), push = try push(env)
        let edited = push.with(exercises: Array(push.exercises.dropFirst()))
        let copy = try env.saveWorkout(edited, onlyOn: 1)
        let schedule = try env.routines.schedule()
        #expect(schedule.days[1] == copy.id)
        #expect(schedule.days[6] == push.id)
        #expect(try env.routines.routine(push.id)?.exercises.count == push.exercises.count, "Saturday's is untouched")
        #expect(try env.routines.routine(copy.id)?.exercises.count == push.exercises.count - 1)
    }

    @Test func everyWeekdayTrainsTheNewPick() throws {
        let env = try makeEnv(), push = try push(env)
        try env.schedule(every: 2, push.id)
        #expect(try env.routines.schedule().days[2] == push.id)
        try env.schedule(every: 2, nil)
        #expect(try env.routines.schedule().days[2] == nil)
    }
}
