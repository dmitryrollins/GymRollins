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
        let until = instant("2026-11-09T00:00:00Z")
        #expect(!LimitsCheckIn.isDue(note: "Ankle", until: until, now: instant("2026-11-08T23:59:59Z"), calendar: utc))
        #expect(LimitsCheckIn.isDue(note: "Ankle", until: until, now: instant("2026-11-09T00:00:00Z"), calendar: utc))
        #expect(LimitsCheckIn.isDue(note: "Ankle", until: until, now: instant("2026-11-15T09:00:00Z"), calendar: utc))
    }

    @Test func aDateSavedLateInTheDayAsksFromThatMorning() {
        let until = instant("2026-11-09T18:00:00Z")
        #expect(LimitsCheckIn.isDue(note: "Ankle", until: until, now: instant("2026-11-09T08:00:00Z"), calendar: utc))
    }

    @Test func nothingIsDueWithoutANoteOrADate() {
        let past = instant("2026-10-15T00:00:00Z")
        let now = instant("2026-11-15T09:00:00Z")
        #expect(!LimitsCheckIn.isDue(note: "", until: past, now: now, calendar: utc))
        #expect(!LimitsCheckIn.isDue(note: "  \n", until: past, now: now, calendar: utc))
        #expect(!LimitsCheckIn.isDue(note: "Ankle", until: nil, now: now, calendar: utc))
    }

    @Test func theDayIsReadInTheCalendarsTimeZone() {
        let auckland = calendar("Pacific/Auckland")
        // Midnight on 9 Nov in Auckland (NZDT, UTC+13) is 11:00 UTC on 8 Nov.
        let until = instant("2026-11-08T11:00:00Z")
        #expect(!LimitsCheckIn.isDue(note: "Ankle", until: until, now: instant("2026-11-08T10:59:00Z"), calendar: auckland))
        #expect(LimitsCheckIn.isDue(note: "Ankle", until: until, now: instant("2026-11-08T11:00:00Z"), calendar: auckland))
        #expect(LimitsCheckIn.isDue(note: "Ankle", until: until, now: instant("2026-11-08T10:59:00Z"), calendar: utc))
    }

    @Test func laterIsTwoWeeksFromTodayAtMidnight() {
        #expect(LimitsCheckIn.laterDate(now: instant("2026-11-09T15:30:00Z"), calendar: utc)
                == instant("2026-11-23T00:00:00Z"))
    }

    @Test func allowedDatesRunFromTomorrowToAYearAhead() {
        let range = LimitsCheckIn.allowedDates(now: instant("2026-11-09T15:30:00Z"), calendar: utc)
        #expect(range.lowerBound == instant("2026-11-10T00:00:00Z"))
        #expect(range.upperBound == instant("2027-11-09T00:00:00Z"))
    }
}
