import Foundation
import Testing
@testable import GymCore

private func calendar(_ zone: String) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: zone)!
    return c
}

private func instant(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

@Suite struct LimitsCheckInTests {
    let utc = calendar("UTC")

    @Test func dueFromTheStartOfTheDayOn() {
        let until = instant("2026-10-26T00:00:00Z")
        #expect(!LimitsCheckIn.isDue(note: "Knee", until: until, now: instant("2026-10-25T23:59:59Z"), calendar: utc))
        #expect(LimitsCheckIn.isDue(note: "Knee", until: until, now: instant("2026-10-26T00:00:00Z"), calendar: utc))
        #expect(LimitsCheckIn.isDue(note: "Knee", until: until, now: instant("2026-11-01T09:00:00Z"), calendar: utc))
    }

    @Test func aDateSavedLateInTheDayAsksFromThatMorning() {
        let until = instant("2026-10-26T18:00:00Z")
        #expect(LimitsCheckIn.isDue(note: "Knee", until: until, now: instant("2026-10-26T08:00:00Z"), calendar: utc))
    }

    @Test func nothingIsDueWithoutANoteOrADate() {
        let past = instant("2026-10-01T00:00:00Z")
        let now = instant("2026-11-01T09:00:00Z")
        #expect(!LimitsCheckIn.isDue(note: "", until: past, now: now, calendar: utc))
        #expect(!LimitsCheckIn.isDue(note: "  \n", until: past, now: now, calendar: utc))
        #expect(!LimitsCheckIn.isDue(note: "Knee", until: nil, now: now, calendar: utc))
    }

    @Test func theDayIsReadInTheCalendarsTimeZone() {
        let auckland = calendar("Pacific/Auckland")
        // Midnight on 26 Oct in Auckland (NZDT, UTC+13) is 11:00 UTC on 25 Oct.
        let until = instant("2026-10-25T11:00:00Z")
        #expect(!LimitsCheckIn.isDue(note: "Knee", until: until, now: instant("2026-10-25T10:59:00Z"), calendar: auckland))
        #expect(LimitsCheckIn.isDue(note: "Knee", until: until, now: instant("2026-10-25T11:00:00Z"), calendar: auckland))
        #expect(LimitsCheckIn.isDue(note: "Knee", until: until, now: instant("2026-10-25T10:59:00Z"), calendar: utc))
    }

    @Test func laterIsTwoWeeksFromTodayAtMidnight() {
        #expect(LimitsCheckIn.laterDate(now: instant("2026-10-26T15:30:00Z"), calendar: utc)
                == instant("2026-11-09T00:00:00Z"))
    }

    @Test func allowedDatesRunFromTomorrowToAYearAhead() {
        let range = LimitsCheckIn.allowedDates(now: instant("2026-10-26T15:30:00Z"), calendar: utc)
        #expect(range.lowerBound == instant("2026-10-27T00:00:00Z"))
        #expect(range.upperBound == instant("2027-10-26T00:00:00Z"))
    }
}
