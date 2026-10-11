import Foundation
import GymSync
import Testing
@testable import GymRollins

/// Codex P2: a goal date synced as `2026-12-31` must show as Dec 31 whatever the device's time zone.
@Suite struct GoalDateTests {
    private static let zones = ["Asia/Tokyo", "America/New_York", "UTC"] // UTC+9, UTC−5, UTC
    private let locale = Locale(identifier: "en_US")

    private func calendar(_ zone: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        return cal
    }

    @Test(arguments: zones)
    func syncedGoalDayShowsTheSameDay(zone: String) throws {
        let cal = calendar(zone)
        let goal = try #require(SyncDay.parse("2026-12-31", calendar: cal))
        #expect(GoalDate.dayMonth(goal, calendar: cal, locale: locale) == "Dec 31")
    }

    @Test(arguments: zones)
    func pickedDateIsSavedAsThatCalendarDay(zone: String) throws {
        let cal = calendar(zone)
        // Late evening on Dec 31 local time (already Jan 1 in UTC for New York, still Dec 31 UTC for Tokyo).
        let picked = try #require(cal.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 30)))
        let saved = GoalDate.normalized(picked, calendar: cal)
        #expect(SyncDay.format(saved, calendar: cal) == "2026-12-31")
        #expect(GoalDate.dayMonth(saved, calendar: cal, locale: locale) == "Dec 31")
        #expect(SyncDay.parse(SyncDay.format(saved, calendar: cal), calendar: cal) == saved)
    }
}
