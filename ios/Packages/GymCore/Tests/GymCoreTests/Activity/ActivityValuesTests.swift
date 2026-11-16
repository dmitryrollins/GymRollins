import Foundation
import Testing
@testable import GymCore

/// Plan 39: what an outside workout and a day of activity are, and how a kind slug reads.
@Suite struct ActivityValuesTests {
    private let start = ISO8601DateFormatter().date(from: "2026-09-25T07:00:00Z")!

    @Test func anOutsideWorkoutKnowsItsMinutesAndWhetherItCounts() {
        let walk = HealthActivity(id: UUID(), kind: "walking", startedAt: start,
                                  endedAt: start.addingTimeInterval(2_700), durationS: 2_700, sourceName: "Apple Watch",
                                  fromWatch: true)
        #expect(walk.minutes == 45)
        #expect(walk.countsAsWorkout)
        let paused = HealthActivity(id: UUID(), kind: "cooldown", startedAt: start,
                                    endedAt: start.addingTimeInterval(900), durationS: 599, sourceName: "Apple Watch")
        #expect(paused.minutes == 9)
        #expect(!paused.countsAsWorkout, "under 10 minutes of active time, whatever the span")
        #expect(!paused.fromWatch)
        #expect(paused.kcal == nil && paused.distanceM == nil && paused.avgHr == nil && paused.maxHr == nil)
    }

    @Test func aDayIsKeyedByItsLocalCalendarDay() throws {
        var warsaw = Calendar(identifier: .gregorian)
        warsaw.timeZone = try #require(TimeZone(identifier: "Europe/Warsaw"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let lateEvening = try #require(ISO8601DateFormatter().date(from: "2026-09-25T22:30:00Z")) // 00:30 in Warsaw
        #expect(ActivityDay.key(for: lateEvening, calendar: warsaw) == "2026-09-26")
        #expect(ActivityDay.key(for: lateEvening, calendar: utc) == "2026-09-25")

        let day = ActivityDay(day: "2026-09-26", steps: 4_210, moveKcal: 210, exerciseMin: 18, standH: nil)
        #expect(day.id == "2026-09-26")
        #expect(day.date(calendar: warsaw).map { ActivityDay.key(for: $0, calendar: warsaw) } == "2026-09-26")
        let notADay = ActivityDay(day: "2026-02-30", steps: 0, moveKcal: 0, exerciseMin: 0, standH: nil)
        #expect(notADay.date(calendar: utc) == nil)
    }

    @Test(arguments: [
        ("walking", "Walk", "figure.walk"), ("running", "Run", "figure.run"),
        ("traditional_strength", "Traditional Strength Training", "figure.strengthtraining.traditional"),
        ("hiit", "HIIT", "figure.highintensity.intervaltraining"), ("other", "Workout", "figure.mixed.cardio"),
    ])
    func aKnownSlugHasItsTitleAndSymbol(slug: String, title: String, symbol: String) {
        let kind = OutsideWorkoutKind(slug: slug)
        #expect(kind.rawValue == slug)
        #expect(kind.title == title)
        #expect(kind.symbol == symbol)
    }

    @Test func anUnknownSlugReadsAsOtherAndEverySlugFitsTheLimit() {
        #expect(OutsideWorkoutKind(slug: "underwater_hockey") == .other)
        #expect(OutsideWorkoutKind(slug: "") == .other)
        #expect(OutsideWorkoutKind.allCases.allSatisfy { (1...100).contains($0.rawValue.count) })
        #expect(Set(OutsideWorkoutKind.allCases.map(\.title)).count == OutsideWorkoutKind.allCases.count)
    }
}
