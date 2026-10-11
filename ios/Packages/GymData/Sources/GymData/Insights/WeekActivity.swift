import Foundation
import GymCore

/// Minutes of training per day for the ISO week containing a given date. Pure; used by the Log
/// tab's week strip.
public struct WeekActivity: Sendable, Equatable {
    public struct Day: Sendable, Equatable, Identifiable {
        public var id: Int { weekday }
        public let weekday: Int      // ISO 1 = Mon … 7 = Sun
        public let date: Date
        public let minutes: Int
        public let isToday: Bool
    }

    public let start: Date
    public let days: [Day]

    public init(workouts: [Workout], containing date: Date, calendar: Calendar = Calendar(identifier: .iso8601)) {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        self.start = start
        self.days = (0..<7).map { offset in
            let dayStart = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            let minutes = workouts
                .filter { calendar.isDate($0.startedAt, inSameDayAs: dayStart) }
                .reduce(0.0) { total, w in
                    total + max(0, (w.endedAt ?? w.startedAt).timeIntervalSince(w.startedAt) - w.pausedSeconds) / 60
                }
            return Day(weekday: offset + 1, date: dayStart, minutes: Int(minutes),
                       isToday: calendar.isDate(date, inSameDayAs: dayStart))
        }
    }
}
