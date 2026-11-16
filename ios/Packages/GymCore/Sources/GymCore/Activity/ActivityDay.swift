import Foundation

/// One local calendar day of Apple Health activity (plan 39): steps from Health's merged statistics, and move, exercise
/// and stand from the day's Activity summary, never summed from raw samples (those double count iPhone + Watch). A day
/// with no data at all isn't stored.
public struct ActivityDay: Codable, Sendable, Equatable, Identifiable {
    /// `YYYY-MM-DD` in the calendar the day was recorded in.
    public let day: String
    public let steps: Int
    public let moveKcal: Double
    public let exerciseMin: Int
    /// Nil without an Apple Watch (no stand goal).
    public let standH: Int?

    public var id: String { day }

    public init(day: String, steps: Int, moveKcal: Double, exerciseMin: Int, standH: Int?) {
        self.day = day
        self.steps = steps
        self.moveKcal = moveKcal
        self.exerciseMin = exerciseMin
        self.standH = standH
    }

    /// `date`'s day in `calendar`, as `YYYY-MM-DD`.
    public static func key(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The start of this day in `calendar`; nil for a key that isn't a real day.
    public func date(calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              Self.key(for: date, calendar: calendar) == day else { return nil }
        return date
    }
}
