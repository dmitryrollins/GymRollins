import Foundation

/// Wire timestamps: ISO 8601 with up to microsecond precision, as Postgres stores `timestamptz`.
///
/// Parsing accepts 0–6 (or more, truncated) fractional digits and `Z`, `+00:00`, `+0000` or `+00` offsets, e.g.
/// PostgREST's `2026-09-26T18:00:00.123456+00:00`. Formatting always writes UTC with exactly six digits, rounded to
/// the nearest microsecond, so a parsed server timestamp formats back to the identical instant (cursor filters
/// like `updated_at > cursor` must not re-match the row the cursor came from).
public enum SyncDate {
    private static let secondsPerDay: Int64 = 86_400

    public static func parse(_ string: String) -> Date? {
        let pattern = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|z|[+-]\d{2}(?::?\d{2})?)?$/
        guard let m = string.wholeMatch(of: pattern),
              let year = Int64(m.1), let month = Int64(m.2), let day = Int64(m.3),
              let hour = Int64(m.4), let minute = Int64(m.5), let second = Int64(m.6),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }
        let micros = m.7.map { fractionMicros(String($0)) } ?? 0
        guard let offset = offsetSeconds(m.8.map(String.init)) else { return nil }
        let seconds = daysFromCivil(year, month, day) * secondsPerDay + hour * 3_600 + minute * 60 + second - offset
        return date(seconds: seconds, micros: micros)
    }

    public static func format(_ date: Date) -> String {
        let totalMicros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
        let seconds = floorDiv(totalMicros, 1_000_000)
        let micros = totalMicros - seconds * 1_000_000
        let days = floorDiv(seconds, secondsPerDay)
        let secondOfDay = seconds - days * secondsPerDay
        let (year, month, day) = civilFromDays(days)
        return String(format: "%04lld-%02lld-%02lldT%02lld:%02lld:%02lld.%06lldZ", year, month, day,
                      secondOfDay / 3_600, secondOfDay % 3_600 / 60, secondOfDay % 60, micros)
    }

    /// Normalizes a date to the microsecond grid the server stores.
    public static func truncatedToWire(_ date: Date) -> Date {
        parse(format(date)) ?? date
    }

    // MARK: - Calendar-free civil date math (Howard Hinnant's algorithms)

    private static func date(seconds: Int64, micros: Int64) -> Date {
        Date(timeIntervalSince1970: Double(seconds) + Double(micros) / 1_000_000)
    }

    private static func fractionMicros(_ digits: String) -> Int64 {
        let six = String((digits + "000000").prefix(6))
        return Int64(six) ?? 0
    }

    private static func offsetSeconds(_ raw: String?) -> Int64? {
        guard let raw, raw != "Z", raw != "z" else { return 0 }
        let sign: Int64 = raw.hasPrefix("-") ? -1 : 1
        let digits = raw.dropFirst().replacingOccurrences(of: ":", with: "")
        guard let hours = Int64(digits.prefix(2)) else { return nil }
        let minutes = digits.count > 2 ? Int64(digits.dropFirst(2)) : 0
        guard let minutes else { return nil }
        return sign * (hours * 3_600 + minutes * 60)
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }

    private static func daysFromCivil(_ year: Int64, _ month: Int64, _ day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = floorDiv(y, 400)
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (month <= 2 ? yoe + era * 400 + 1 : yoe + era * 400, month, day)
    }
}

/// Postgres `date` columns (e.g. `goal_date`) as `yyyy-MM-dd` in the device's calendar and time zone.
public enum SyncDay {
    public static func format(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func parse(_ string: String, calendar: Calendar = .current) -> Date? {
        let parts = string.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// The JSON coders used for every sync payload.
public enum SyncJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(SyncDate.format(date))
        }
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let raw = try c.decode(String.self)
            guard let date = SyncDate.parse(raw) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognized timestamp \(raw)")
            }
            return date
        }
        return d
    }
}
