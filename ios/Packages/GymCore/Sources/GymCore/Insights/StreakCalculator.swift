import Foundation

public struct Streak: Equatable, Sendable {
    /// Consecutive goal-met weeks, ending with this week when it's already met, else with last week.
    public let current: Int
    public let longest: Int
    /// Workout days per week needed (1…7).
    public let goal: Int
    /// Distinct days with a workout so far this week.
    public let thisWeekDays: Int
    public let thisWeekMet: Bool

    public init(current: Int, longest: Int, goal: Int, thisWeekDays: Int, thisWeekMet: Bool) {
        self.current = current
        self.longest = longest
        self.goal = goal
        self.thisWeekDays = thisWeekDays
        self.thisWeekMet = thisWeekMet
    }
}

/// Weekly streaks: a week (Monday–Sunday in the calendar's time zone) meets the goal when it has at least `goal`
/// distinct days with a finished workout. The current week is in progress and never breaks the streak; any
/// earlier week below the goal (a rest week included) does. Keep in sync with `_shared/insights.ts`.
public enum StreakCalculator {
    public static func compute(workoutDates: [Date], goal rawGoal: Int, now: Date, calendar: Calendar) -> Streak {
        let goal = min(max(rawGoal, 1), 7)
        let perWeek = daysPerWeek(workoutDates.filter { $0 <= now }, calendar: calendar)
        let thisWeek = TrainingWeek.interval(containing: now, calendar: calendar).start
        let thisWeekDays = perWeek[thisWeek] ?? 0
        let met = { (week: Date) in (perWeek[week] ?? 0) >= goal }

        var current = 0
        var week = met(thisWeek) ? thisWeek : previous(thisWeek, calendar)
        while met(week) {
            current += 1
            week = previous(week, calendar)
        }

        var longest = 0
        var run = 0
        var last: Date?
        for week in perWeek.keys.sorted() where met(week) {
            run = last.map { previous(week, calendar) == $0 } == true ? run + 1 : 1
            longest = max(longest, run)
            last = week
        }
        return Streak(current: current, longest: longest, goal: goal, thisWeekDays: thisWeekDays,
                      thisWeekMet: met(thisWeek))
    }

    /// True when finishing a workout at `finished` brings its week from below the goal to meeting it (a second
    /// workout on an already-counted day doesn't). `otherDates` are the other finished workouts.
    public static func completesWeeklyGoal(otherDates: [Date], finished: Date, goal rawGoal: Int,
                                           calendar: Calendar) -> Bool {
        let goal = min(max(rawGoal, 1), 7)
        let week = TrainingWeek.interval(containing: finished, calendar: calendar)
        let before = Set(otherDates.filter { week.contains($0) && $0 != week.end }.map(calendar.startOfDay))
        let after = before.union([calendar.startOfDay(for: finished)])
        return before.count < goal && after.count >= goal
    }

    /// Week start → number of distinct workout days in it.
    private static func daysPerWeek(_ dates: [Date], calendar: Calendar) -> [Date: Int] {
        var days: [Date: Set<Date>] = [:]
        for date in dates {
            let week = TrainingWeek.interval(containing: date, calendar: calendar).start
            days[week, default: []].insert(calendar.startOfDay(for: date))
        }
        return days.mapValues(\.count)
    }

    private static func previous(_ weekStart: Date, _ calendar: Calendar) -> Date {
        let dayInPreviousWeek = calendar.date(byAdding: .day, value: -3, to: weekStart) ?? weekStart
        return TrainingWeek.interval(containing: dayInPreviousWeek, calendar: calendar).start
    }
}
