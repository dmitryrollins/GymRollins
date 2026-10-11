import Foundation

/// Goal dates are calendar days, not instants: stored as midnight in the device's calendar and time zone — the
/// same convention `SyncDay` uses to read and write the server's `date` column — and always formatted in that
/// same calendar, so a goal of 31 Dec shows as 31 Dec in every time zone.
enum GoalDate {
    /// The start of `date`'s day in `calendar` (what a date picker's selection is saved as).
    static func normalized(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    /// "31 Dec" / "Dec 31" (per locale), read in `calendar`'s time zone.
    static func dayMonth(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .day().month(.abbreviated)
        return date.formatted(style)
    }
}
