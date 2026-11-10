import Foundation

/// When the injury note's end date has come, and the dates Not yet can move it to. Dates are calendar days in
/// `calendar`, the way the profile stores them.
public enum LimitsCheckIn {
    /// Not yet offers a date this many days from today.
    public static let laterDays = 14
    /// The furthest ahead an end date can be.
    public static let maxDaysAhead = 365

    /// On or after `until`'s day, when there's a note to ask about. A date with no note means nothing.
    public static func isDue(note: String, until: Date?, now: Date, calendar: Calendar) -> Bool {
        guard let until, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return calendar.startOfDay(for: now) >= calendar.startOfDay(for: until)
    }

    /// The date Not yet starts on: two weeks from today.
    public static func laterDate(now: Date, calendar: Calendar) -> Date {
        day(laterDays, from: now, calendar: calendar)
    }

    /// Tomorrow to a year ahead. An end date of today or earlier would ask straight away.
    public static func allowedDates(now: Date, calendar: Calendar) -> ClosedRange<Date> {
        day(1, from: now, calendar: calendar)...day(maxDaysAhead, from: now, calendar: calendar)
    }

    private static func day(_ offset: Int, from now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }
}
