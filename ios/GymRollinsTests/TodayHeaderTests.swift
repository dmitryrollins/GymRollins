import Testing
@testable import GymRollins

/// The workout pill shows only the day and the number of exercises (owner, 2026-11-19: only what matters at
/// a glance); "Rest day · optional", "edited for today" and the like stay for VoiceOver only.
@Suite struct TodayHeaderTests {
    private func subtitle(_ day: String, _ exercises: Int) -> String {
        TodayHeader.subtitle(day: day, exercises: exercises).replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    @Test func theDayAndHowManyExercises() {
        #expect(subtitle("Today", 7) == "Today \u{00B7} 7 exercises")
        #expect(subtitle("Monday", 1) == "Monday \u{00B7} 1 exercise")
    }

    @Test func nothingToDoShowsJustTheDay() {
        #expect(subtitle("Tomorrow", 0) == "Tomorrow")
    }

    /// Wrapped, it breaks between the parts only.
    @Test func partsKeepTheirWordsTogether() {
        let raw = TodayHeader.subtitle(day: "Today", exercises: 7)
        #expect(raw == "Today \u{00B7} 7\u{00A0}exercises")
    }
}
