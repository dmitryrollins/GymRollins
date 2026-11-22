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
        #expect(paused.avgPowerW == nil && paused.avgCadenceRpm == nil && paused.totalKcal == nil)
    }

    @Test func aRideKeepsItsPowerCadenceAndTotalCalories() throws {
        let ride = HealthActivity(id: UUID(), kind: "cycling", startedAt: start, endedAt: start.addingTimeInterval(810),
                                  durationS: 810, kcal: 40, totalKcal: 48, avgHr: 118, maxHr: 141, avgPowerW: 138,
                                  avgCadenceRpm: 62, sourceName: "Apple Watch", fromWatch: true)
        #expect(ride.avgPowerW == 138 && ride.avgCadenceRpm == 62 && ride.totalKcal == 48)
        let back = try JSONDecoder().decode(HealthActivity.self, from: JSONEncoder().encode(ride))
        #expect(back == ride)
    }

    @Test func anOutsideWorkoutSavedBeforeTheNewFieldsStillDecodes() throws {
        let walk = HealthActivity(id: UUID(), kind: "walking", startedAt: start, endedAt: start.addingTimeInterval(60),
                                  durationS: 60, kcal: 5, sourceName: "Strava")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(walk)) as? [String: Any])
        for key in ["avgPowerW", "avgCadenceRpm", "totalKcal"] { object[key] = nil }
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(HealthActivity.self, from: old) == walk)
    }

    /// Apple Fitness's "Total": active plus resting energy, only when Health has both and the sum makes sense.
    @Test(arguments: [
        (40.0, 8.0, 48.0), (40.0, 0.0, 40.0), (0.0, 12.5, 12.5),
    ] as [(Double, Double, Double)])
    func totalCaloriesAreActivePlusResting(active: Double, basal: Double, total: Double) {
        #expect(HealthActivity.totalKcal(active: active, basal: basal) == total)
    }

    @Test func totalCaloriesNeedBothAndNeverComeOutBelowTheActive() {
        #expect(HealthActivity.totalKcal(active: 40, basal: nil) == nil, "no resting energy in Health")
        #expect(HealthActivity.totalKcal(active: nil, basal: 8) == nil, "resting alone isn't a total")
        #expect(HealthActivity.totalKcal(active: nil, basal: nil) == nil)
        #expect(HealthActivity.totalKcal(active: 40, basal: -5) == nil, "below the active kcal")
    }

    @Test func aDayIsKeyedByItsLocalCalendarDay() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let lateEvening = try #require(ISO8601DateFormatter().date(from: "2026-09-25T22:30:00Z")) // 00:30 in Berlin
        #expect(ActivityDay.key(for: lateEvening, calendar: berlin) == "2026-09-26")
        #expect(ActivityDay.key(for: lateEvening, calendar: utc) == "2026-09-25")

        let day = ActivityDay(day: "2026-09-26", steps: 4_210, moveKcal: 210, exerciseMin: 18, standH: nil)
        #expect(day.id == "2026-09-26")
        #expect(day.date(calendar: berlin).map { ActivityDay.key(for: $0, calendar: berlin) } == "2026-09-26")
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
