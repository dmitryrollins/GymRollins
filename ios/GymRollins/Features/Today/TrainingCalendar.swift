import Foundation

/// What a day holds on Today's calendar (owner, 2026-11-19: see which day is still empty and which is not).
enum TrainingDayStatus: Equatable {
    /// A workout was finished that day.
    case done
    /// Today or later, with a workout planned.
    case planned
    /// Nothing done, and (today or later) nothing planned: a rest day offering only an optional workout is empty.
    case empty
}

/// Each day's status from one read of the history and the plan (`AppEnvironment.trainingCalendar()`), and a month's
/// counts for the calendar's stats row.
struct TrainingCalendar {
    /// The days with a finished workout, as day keys ("2026-11-19").
    let doneDays: Set<String>
    /// Today's day key: a day before it is done or empty.
    let today: String
    let calendar: Calendar
    /// Whether today or a later day has a workout planned.
    let isPlanned: (Date) -> Bool

    func status(on date: Date) -> TrainingDayStatus {
        let day = TodayPlan.dayKey(date, calendar: calendar)
        if doneDays.contains(day) { return .done }
        return day >= today && isPlanned(date) ? .planned : .empty
    }

    struct MonthStats: Equatable {
        var done = 0
        var planned = 0
        /// Days from today on with nothing planned: the ones still to fill. Past days without a workout aren't counted.
        var empty = 0
    }

    /// The counts for the month `date` falls in.
    func stats(forMonthOf date: Date) -> MonthStats {
        guard let month = calendar.dateInterval(of: .month, for: date) else { return MonthStats() }
        var stats = MonthStats()
        var start = month.start
        while start < month.end {
            let noon = calendar.date(byAdding: .hour, value: 12, to: start) ?? start
            switch status(on: noon) {
            case .done: stats.done += 1
            case .planned: stats.planned += 1
            case .empty where TodayPlan.dayKey(noon, calendar: calendar) >= today: stats.empty += 1
            case .empty: break
            }
            start = calendar.date(byAdding: .day, value: 1, to: start) ?? month.end
        }
        return stats
    }
}
