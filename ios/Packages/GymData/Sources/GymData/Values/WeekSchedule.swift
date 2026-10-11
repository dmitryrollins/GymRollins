import Foundation

/// ISO weekday (1 = Monday … 7 = Sunday) -> routine id (nil = rest).
public struct WeekSchedule: Codable, Sendable, Equatable {
    public let days: [Int: UUID]

    public init(days: [Int: UUID]) { self.days = days }

    public func routineId(on date: Date, calendar: Calendar = .current) -> UUID? {
        days[Self.isoWeekday(date, calendar: calendar)]
    }

    public static func isoWeekday(_ date: Date, calendar: Calendar = .current) -> Int {
        let weekday = calendar.component(.weekday, from: date) // 1 = Sunday
        return weekday == 1 ? 7 : weekday - 1
    }
}
