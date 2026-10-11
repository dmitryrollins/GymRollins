import Foundation
import Testing
@testable import GymCore

struct StreakCalculatorTests {
    typealias F = InsightsFixture
    let utc = F.utc()

    /// Workout days: `perWeek` days (Mon, Tue, …) in each of the weeks starting at the given Mondays.
    private func days(_ mondays: [String], perWeek: Int) -> [Date] {
        mondays.flatMap { monday in
            (0..<perWeek).map { F.date("\(monday)T18:00:00Z").addingTimeInterval(Double($0) * 86_400) }
        }
    }

    @Test func noWorkoutsNoStreak() {
        let s = StreakCalculator.compute(workoutDates: [], goal: 3, now: F.date("2026-09-26T09:00:00Z"), calendar: utc)
        #expect(s == Streak(current: 0, longest: 0, goal: 3, thisWeekDays: 0, thisWeekMet: false))
    }

    @Test func consecutiveWeeksIncludingCompletedCurrentWeek() {
        let dates = days(["2026-09-07", "2026-09-14", "2026-09-21"], perWeek: 3)
        let s = StreakCalculator.compute(workoutDates: dates, goal: 3, now: F.date("2026-09-26T09:00:00Z"), calendar: utc)
        #expect(s.current == 3)
        #expect(s.longest == 3)
        #expect(s.thisWeekDays == 3)
        #expect(s.thisWeekMet)
    }

    @Test func currentWeekInProgressDoesntBreakTheStreak() {
        let dates = days(["2026-09-07", "2026-09-14"], perWeek: 3) + days(["2026-09-21"], perWeek: 1)
        let s = StreakCalculator.compute(workoutDates: dates, goal: 3, now: F.date("2026-09-26T09:00:00Z"), calendar: utc)
        #expect(s.current == 2)
        #expect(s.thisWeekDays == 1)
        #expect(!s.thisWeekMet)
    }

    @Test func restWeekBreaksTheStreakButLongestRemembers() {
        let dates = days(["2026-08-10", "2026-08-17", "2026-08-24", "2026-08-31"], perWeek: 4)
            + days(["2026-09-14", "2026-09-21"], perWeek: 4) // 7 Sep: rest week
        let s = StreakCalculator.compute(workoutDates: dates, goal: 4, now: F.date("2026-09-26T09:00:00Z"), calendar: utc)
        #expect(s.current == 2)
        #expect(s.longest == 4)
    }

    @Test func missedLastWeekResetsCurrent() {
        let dates = days(["2026-09-07"], perWeek: 3) + days(["2026-09-14"], perWeek: 2)
        let s = StreakCalculator.compute(workoutDates: dates, goal: 3, now: F.date("2026-09-22T09:00:00Z"), calendar: utc)
        #expect(s.current == 0)
        #expect(s.longest == 1)
    }

    @Test func twoWorkoutsOnOneDayCountOnce() {
        let monday = F.date("2026-09-21T08:00:00Z")
        let dates = [monday, monday.addingTimeInterval(8 * 3_600), monday.addingTimeInterval(86_400)]
        let s = StreakCalculator.compute(workoutDates: dates, goal: 3, now: F.date("2026-09-26T09:00:00Z"), calendar: utc)
        #expect(s.thisWeekDays == 2)
        #expect(s.current == 0)
    }

    @Test func futureDatesAreIgnored() {
        let dates = days(["2026-09-21"], perWeek: 3) + [F.date("2026-10-01T09:00:00Z")]
        let s = StreakCalculator.compute(workoutDates: dates, goal: 3, now: F.date("2026-09-23T20:00:00Z"), calendar: utc)
        #expect(s.thisWeekDays == 3)
        #expect(s.current == 1)
    }

    @Test func weekBoundaryFollowsTheTimeZone() {
        // Sunday 23:30 UTC = Monday 01:30 in Warsaw: in UTC that's week 1's 3rd day, in Warsaw week 2's 1st.
        let dates = [F.date("2026-09-21T10:00:00Z"), F.date("2026-09-23T10:00:00Z"), F.date("2026-09-27T23:30:00Z")]
        let now = F.date("2026-09-28T10:00:00Z")
        let inUTC = StreakCalculator.compute(workoutDates: dates, goal: 3, now: now, calendar: utc)
        #expect(inUTC.current == 1)
        #expect(inUTC.thisWeekDays == 0)
        let warsaw = TrainingWeek.calendar(timeZone: TimeZone(identifier: "Europe/Warsaw")!)
        let inWarsaw = StreakCalculator.compute(workoutDates: dates, goal: 3, now: now, calendar: warsaw)
        #expect(inWarsaw.current == 0)
        #expect(inWarsaw.thisWeekDays == 1)
    }

    @Test func streakAcrossDSTWeeks() {
        let warsaw = TrainingWeek.calendar(timeZone: TimeZone(identifier: "Europe/Warsaw")!)
        // Weeks of 19 Oct (DST ends Sun 25 Oct) and 26 Oct 2026.
        let dates = ["2026-10-19", "2026-10-21", "2026-10-26", "2026-10-28"].map { F.date("\($0)T10:00:00Z") }
        let s = StreakCalculator.compute(workoutDates: dates, goal: 2, now: F.date("2026-10-29T10:00:00Z"),
                                         calendar: warsaw)
        #expect(s.current == 2)
    }

    @Test func goalIsClampedToAWeek() {
        let s = StreakCalculator.compute(workoutDates: [], goal: 0, now: F.date("2026-09-26T09:00:00Z"), calendar: utc)
        #expect(s.goal == 1)
        #expect(StreakCalculator.compute(workoutDates: [], goal: 9, now: .now, calendar: utc).goal == 7)
    }

    @Test func completesWeeklyGoalOnlyWhenThisWorkoutCrossesIt() {
        let others = days(["2026-09-21"], perWeek: 2) // Mon, Tue
        let thu = F.date("2026-09-24T18:00:00Z")
        #expect(StreakCalculator.completesWeeklyGoal(otherDates: others, finished: thu, goal: 3, calendar: utc))
        #expect(!StreakCalculator.completesWeeklyGoal(otherDates: others, finished: thu, goal: 4, calendar: utc))
        // Already met before, or a second workout on an already-counted day: no celebration.
        let met = days(["2026-09-21"], perWeek: 3)
        #expect(!StreakCalculator.completesWeeklyGoal(otherDates: met, finished: thu, goal: 3, calendar: utc))
        let tueAgain = F.date("2026-09-22T20:00:00Z")
        #expect(!StreakCalculator.completesWeeklyGoal(otherDates: others, finished: tueAgain, goal: 3, calendar: utc))
        // Last week's workouts don't count toward this one.
        #expect(!StreakCalculator.completesWeeklyGoal(otherDates: days(["2026-09-14"], perWeek: 3), finished: thu,
                                                      goal: 2, calendar: utc))
    }
}
