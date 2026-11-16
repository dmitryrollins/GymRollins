import Foundation
import GymCore
import Testing
@testable import GymData

@Suite struct WeekActivityTests {
    var cal: Calendar { var c = Calendar(identifier: .iso8601); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    @Test func minutesPerIsoDayForTheWeekOfDate() {
        let tue = ISO8601DateFormatter().date(from: "2026-09-22T22:38:41Z")!
        let workouts = [
            Workout(startedAt: tue, endedAt: tue.addingTimeInterval(3_957), name: "Pull"),
            Workout(startedAt: tue.addingTimeInterval(-7 * 86_400), endedAt: tue.addingTimeInterval(-7 * 86_400 + 600), name: "Old"),
        ]
        let sat = ISO8601DateFormatter().date(from: "2026-09-26T09:00:00Z")!
        let week = WeekActivity(workouts: workouts, containing: sat, calendar: cal)
        #expect(week.days.map(\.weekday) == [1, 2, 3, 4, 5, 6, 7])
        #expect(week.days[1].minutes == 65)
        #expect(week.days.filter { $0.minutes > 0 }.count == 1)
        #expect(week.days[5].isToday)
        #expect(week.start == ISO8601DateFormatter().date(from: "2026-09-21T00:00:00Z"))
    }

    /// Plan 39: an outside workout's active minutes are counted apart, so the strip can show them in a lighter shade.
    @Test func outsideWorkoutMinutesAreCountedApart() {
        let tue = ISO8601DateFormatter().date(from: "2026-09-22T07:00:00Z")!
        let walk = HealthActivity(id: UUID(), kind: "walking", startedAt: tue, endedAt: tue.addingTimeInterval(3_000),
                                  durationS: 2_700, sourceName: "Apple Watch", fromWatch: true)
        let lastWeek = HealthActivity(id: UUID(), kind: "running", startedAt: tue.addingTimeInterval(-7 * 86_400),
                                      endedAt: tue.addingTimeInterval(-7 * 86_400 + 1_800), durationS: 1_800,
                                      sourceName: "Strava")
        let sat = ISO8601DateFormatter().date(from: "2026-09-26T09:00:00Z")!
        let week = WeekActivity(workouts: [], outside: [walk, lastWeek], containing: sat, calendar: cal)
        #expect(week.days[1].minutes == 0)
        #expect(week.days[1].outsideMinutes == 45, "active time, pauses left out")
        #expect(week.days.map(\.outsideMinutes).reduce(0, +) == 45)
    }
}
