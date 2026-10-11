import Foundation

/// Calendar days written yyyy-MM-dd (the `today` change's `date`, Today's plan day). Mirrored in
/// supabase/functions/_shared/plan-validation.ts (`dayNumber`).
public enum PlanDay {
    /// The day `date` falls on in `calendar` (the owner's local day by default).
    public static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Days since 1970-01-01 for a real (proleptic Gregorian) date written yyyy-MM-dd; nil for anything else.
    public static func number(_ value: String) -> Int? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard value.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...daysIn(month: month, year: year)).contains(day) else { return nil }
        return daysFromCivil(year: year, month: month, day: day)
    }

    /// The yyyy-MM-dd `days` after `day` (nil when `day` isn't a date).
    public static func adding(_ days: Int, to day: String) -> String? {
        guard let n = number(day) else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        return key(Date(timeIntervalSince1970: TimeInterval(n + days) * 86_400), calendar: utc)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Howard Hinnant's days_from_civil.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
