import Foundation
import GymCore
import Testing
import UIKit
@testable import GymRollins

/// Plan 39: the words and metrics for outside workouts and days of activity (in Apple Fitness' look, §4.1), and every
/// kind's SF Symbol.
@Suite struct ActivityTextTests {
    private let start = ISO8601DateFormatter().date(from: "2026-09-25T07:00:00Z")!

    private func walk(start: Date? = nil, kcal: Double? = 180, distanceM: Double? = 3_400, avgHr: Int? = 102,
                      maxHr: Int? = 121) -> HealthActivity {
        let begin = start ?? self.start
        return HealthActivity(id: UUID(), kind: "walking", startedAt: begin, endedAt: begin.addingTimeInterval(2_700),
                              durationS: 2_700, kcal: kcal, distanceM: distanceM, avgHr: avgHr, maxHr: maxHr,
                              sourceName: "Apple Watch", fromWatch: true)
    }

    /// The owner's LifeFitness ride: 5 min 8 s, 2.26 km, 40 of 48 kcal, 138 W, 62 rpm.
    private func ride(durationS: Double = 308) -> HealthActivity {
        HealthActivity(id: UUID(), kind: "cycling", startedAt: start, endedAt: start.addingTimeInterval(durationS),
                       durationS: durationS, kcal: 40, totalKcal: 48, distanceM: 2_260, avgHr: 128, maxHr: 151,
                       avgPowerW: 138, avgCadenceRpm: 62, sourceName: "LifeFitness", fromWatch: true)
    }

    // MARK: Detail

    @Test func theDetailListsEveryMetricInFitnessOrder() {
        let metrics = ActivityText.details(ride(), unit: .kg)
        #expect(metrics == [
            MetricReading(key: "duration", label: "Workout Time", value: "0:05:08", unit: nil,
                          spoken: "5 minutes 8 seconds", tint: .time),
            MetricReading(key: "distance", label: "Distance", value: "2.26", unit: "KM", spoken: "2.26 kilometres",
                          tint: .distance),
            MetricReading(key: "kcal", label: "Active Calories", value: "40", unit: "KCAL",
                          spoken: "40 kilocalories", tint: .calories),
            MetricReading(key: "totalKcal", label: "Total Calories", value: "48", unit: "KCAL",
                          spoken: "48 kilocalories", tint: .calories),
            MetricReading(key: "power", label: "Avg. Power", value: "138", unit: "W", spoken: "138 watts",
                          tint: .power),
            MetricReading(key: "cadence", label: "Avg. Cadence", value: "62", unit: "RPM",
                          spoken: "62 revolutions per minute", tint: .cadence),
            MetricReading(key: "avgHr", label: "Avg. Heart Rate", value: "128", unit: "BPM",
                          spoken: "128 beats per minute", tint: .heartRate),
            MetricReading(key: "maxHr", label: "Max Heart Rate", value: "151", unit: "BPM",
                          spoken: "151 beats per minute", tint: .heartRate),
        ])
    }

    @Test func distanceFollowsTheProfileUnit() {
        let miles = ActivityText.details(ride(), unit: .lb).first { $0.key == "distance" }
        #expect(miles?.value == "1.40")
        #expect(miles?.unit == "MI")
        #expect(miles?.spoken == "1.40 miles")
        #expect(ActivityText.details(walk(distanceM: 0), unit: .kg).allSatisfy { $0.key != "distance" })
    }

    @Test func missingValuesAreLeftOut() {
        #expect(ActivityText.details(walk(), unit: .kg).map(\.key)
            == ["duration", "distance", "kcal", "avgHr", "maxHr"])
        #expect(ActivityText.details(walk(kcal: nil, distanceM: nil, avgHr: nil, maxHr: nil), unit: .kg).map(\.key)
            == ["duration"])
    }

    @Test func timeIsHoursMinutesSeconds() {
        #expect(ActivityText.clock(308) == "0:05:08")
        #expect(ActivityText.clock(2_700) == "0:45:00")
        #expect(ActivityText.clock(3_725) == "1:02:05")
        #expect(ActivityText.clock(-4) == "0:00:00")
        #expect(ActivityText.spokenDuration(3_725) == "1 hour 2 minutes 5 seconds")
        #expect(ActivityText.spokenDuration(3_600) == "1 hour")
        #expect(ActivityText.spokenDuration(61) == "1 minute 1 second")
        #expect(ActivityText.spokenDuration(0) == "0 seconds")
    }

    @Test func theHeadlineIsTheDistanceElseCaloriesElseTime() {
        #expect(ActivityText.headline(ride(), unit: .kg)
            == MetricReading(key: "distance", label: "Distance", value: "2.26", unit: "KM", spoken: "2.26 kilometres",
                             tint: .workout))
        let calories = ActivityText.headline(walk(distanceM: nil), unit: .kg)
        #expect(calories.key == "kcal" && calories.value == "180" && calories.unit == "KCAL")
        #expect(calories.tint == .workout)
        let time = ActivityText.headline(walk(kcal: nil, distanceM: nil), unit: .kg)
        #expect(time.key == "duration" && time.value == "0:45:00" && time.unit == nil && time.tint == .workout)
    }

    @Test func theCardSaysTheKindDateDurationAndSource() {
        #expect(ActivityText.title(walk()) == "Walk")
        #expect(ActivityText.durationAndSource(walk()) == "45 min \u{00B7} Apple Watch")
        let label = ActivityText.cardLabel(walk(), unit: .kg)
        #expect(label.hasPrefix("Walk, 3.40 kilometres, "), "\(label)")
        #expect(label.hasSuffix(", 45 min, Apple Watch"), "\(label)")
    }

    // MARK: A GymRollins workout

    @Test func theMeasuredBlockHasCaloriesHeartRateAndPowerWhenThereIsOne() {
        #expect(ActivityText.measured(walk(kcal: 412, avgHr: 128, maxHr: 162)).map(\.key) == ["kcal", "avgHr", "maxHr"])
        #expect(ActivityText.measured(ride()).map(\.key) == ["kcal", "avgHr", "maxHr", "power"])
        #expect(ActivityText.measured(walk(kcal: nil, maxHr: nil)).map(\.value) == ["102"])
        #expect(ActivityText.measured(walk(kcal: nil, avgHr: nil, maxHr: nil)).isEmpty)
        #expect(ActivityText.measuredTitle(walk()) == "Apple Watch measured")
    }

    @Test func theWeeksMeasuredCaloriesCountOnlyThisWeek() {
        let lastWeek = walk(start: start.addingTimeInterval(-8 * 86_400), kcal: 300)
        #expect(ActivityText.weekKcal([walk(), lastWeek], containing: start.addingTimeInterval(86_400)) == 180)
        #expect(ActivityText.otherKcalLine(1_240) == "+ \(1_240.formatted()) kcal from other activities (measured)")
    }

    // MARK: Days of activity

    @Test func aDayIsStepsMoveExerciseAndStandWhenAWatchCountedIt() {
        let day = ActivityDay(day: "2026-09-26", steps: 4_210, moveKcal: 210.4, exerciseMin: 18, standH: 6)
        #expect(ActivityText.dayMetrics(day) == [
            MetricReading(key: "steps", label: "Steps", value: 4_210.formatted(), unit: nil,
                          spoken: 4_210.formatted(), tint: .steps),
            MetricReading(key: "move", label: "Move", value: "210", unit: "KCAL", spoken: "210 kilocalories",
                          tint: .calories),
            MetricReading(key: "exercise", label: "Exercise", value: "18", unit: "MIN", spoken: "18 minutes",
                          tint: .exercise),
            MetricReading(key: "stand", label: "Stand", value: "6", unit: "HRS", spoken: "6 hours", tint: .stand),
        ])
        let noWatch = ActivityDay(day: "2026-09-26", steps: 1, moveKcal: 1, exerciseMin: 1, standH: nil)
        #expect(ActivityText.dayMetrics(noWatch).map(\.spoken) == ["1", "1 kilocalorie", "1 minute"])
    }

    @Test func todayHasZerosBeforeAnyData() {
        #expect(ActivityText.dayMetrics(nil).map(\.value) == ["0", "0", "0"])
        #expect(ActivityText.spokenSummary(ActivityText.dayMetrics(nil))
            == "Steps 0, Move 0 kilocalories, Exercise 0 minutes")
    }

    @Test func everySymbolExists() {
        for kind in OutsideWorkoutKind.allCases { #expect(UIImage(systemName: kind.symbol) != nil, "\(kind)") }
        #expect(UIImage(systemName: "applewatch") != nil)
        #expect(UIImage(systemName: "chevron.right") != nil)
    }
}
