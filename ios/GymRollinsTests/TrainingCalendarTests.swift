import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Today's calendar marks each day (owner, 2026-11-19: see which day is still empty and which is not): done when a workout was finished that day, planned when one is planned from today on, else empty. The seed's
/// week: Monday Push, Wednesday Pull, Friday Upper, Saturday Push; Saturday 26 Sep is today.
@MainActor
@Suite struct TrainingCalendarTests {
    private func makeEnv(now: String = "2026-09-26T09:00:00Z") throws -> AppEnvironment {
        let defaults = try #require(UserDefaults(suiteName: "TrainingCalendarTests.\(UUID())"))
        return try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow", now]), defaults: defaults)
    }

    /// `days` days from today, at midday (before today when negative).
    private func date(_ days: Int, _ env: AppEnvironment) -> Date {
        let noon = TodayDay.today.date(now: env.now())
        return Calendar.current.date(byAdding: .day, value: days, to: noon) ?? noon
    }

    private func finishWorkout(on date: Date, _ env: AppEnvironment) throws {
        let entry = WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: 60, reps: 8, done: true)])
        try env.workouts.save(Workout(startedAt: date, endedAt: date.addingTimeInterval(3_000), name: "Push",
                                      entries: [entry]))
    }

    private func pull(_ env: AppEnvironment) throws -> Routine {
        try #require(try env.routines.all().first { $0.name.hasPrefix("Pull") })
    }

    @Test func trainingDaysArePlannedAndRestDaysEmpty() throws {
        let env = try makeEnv()
        let days = env.trainingCalendar()
        #expect((0...4).map { days.status(on: date($0, env)) } == [.planned, .empty, .planned, .empty, .planned])
    }

    @Test func aFinishedWorkoutMarksItsDayDoneEvenOnAPlannedDay() throws {
        let env = try makeEnv()
        try finishWorkout(on: date(-2, env), env)
        try finishWorkout(on: date(0, env), env)
        let days = env.trainingCalendar()
        #expect(days.status(on: date(-2, env)) == .done)
        #expect(days.status(on: date(0, env)) == .done, "today's Push is done")
        #expect(days.status(on: date(-3, env)) == .empty, "a past day with nothing done")
        #expect(days.status(on: date(-5, env)) == .empty, "a past training day isn't planned any more")
    }

    /// An agent's switch on a rest day plans it; the owner's change that empties a day leaves it empty. Reading the
    /// calendar takes and removes nothing.
    @Test func oneDayChangesCount() throws {
        let env = try makeEnv(), pull = try pull(env)
        let sunday = TodayPlan.dayKey(date(1, env))
        PlannedSwitchStore(defaults: env.defaults).set(pull.id, on: sunday)
        let monday = try env.laterDay(on: date(2, env))
        let emptied = monday.plan.exercises.reduce(monday.plan) { $0.deleting($1.id) }
        env.laterDaySaver(on: date(2, env), scheduled: monday.scheduled?.id).save(emptied)

        let days = env.trainingCalendar()
        #expect(days.status(on: date(1, env)) == .planned)
        #expect(days.status(on: date(2, env)) == .empty)
        #expect(PlannedSwitchStore(defaults: env.defaults).all()[sunday] == pull.id)
        #expect(LaterDayPlanStore(defaults: env.defaults).days().contains(TodayPlan.dayKey(date(2, env))))
    }

    /// Sunday 27 Sep rests: Today offers the next workout as optional, which leaves the day empty until it's chosen.
    @Test func aRestDaysOptionalSuggestionIsEmptyUntilChosen() throws {
        let env = try makeEnv(now: "2026-09-27T09:00:00Z")
        #expect(try env.todaysPlan().plan.kind == .restDaySuggestion)
        #expect(env.trainingCalendar().status(on: date(0, env)) == .empty)

        let today = try env.todaysPlan().plan
        env.todayPlanStore.save(today.switched(to: try pull(env)))
        #expect(env.trainingCalendar().status(on: date(0, env)) == .planned)
    }

    /// September from Saturday 26: one workout done on the 24th; 26, 28 and 30 planned; 27 and 29 still empty.
    /// October has 18 training days (Mondays, Wednesdays, Fridays and Saturdays) and 13 empty ones.
    @Test func theMonthCountsDonePlannedAndDaysStillEmpty() throws {
        let env = try makeEnv()
        try finishWorkout(on: date(-2, env), env)
        let days = env.trainingCalendar()
        #expect(days.stats(forMonthOf: env.now()) == .init(done: 1, planned: 3, empty: 2))
        #expect(days.stats(forMonthOf: date(20, env)) == .init(done: 0, planned: 18, empty: 13))
    }
}
