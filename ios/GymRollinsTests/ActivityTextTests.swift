import Foundation
import GymCore
import Testing
import UIKit
@testable import GymRollins

/// Plan 39: the words for outside workouts and days of activity, and every kind's SF Symbol.
@Suite struct ActivityTextTests {
    private let start = ISO8601DateFormatter().date(from: "2026-09-25T07:00:00Z")!

    private func walk(start: Date? = nil, kcal: Double? = 180, distanceM: Double? = 3_400, avgHr: Int? = 102,
                      maxHr: Int? = 121) -> HealthActivity {
        let begin = start ?? self.start
        return HealthActivity(id: UUID(), kind: "walking", startedAt: begin, endedAt: begin.addingTimeInterval(2_700),
                              durationS: 2_700, kcal: kcal, distanceM: distanceM, avgHr: avgHr, maxHr: maxHr,
                              sourceName: "Apple Watch", fromWatch: true)
    }

    @Test func factsAreTheDistanceInTheOwnersUnitThenCaloriesThenTheSource() {
        #expect(ActivityText.facts(walk(), unit: .kg) == "3.4 km \u{00B7} 180 kcal \u{00B7} Apple Watch")
        #expect(ActivityText.facts(walk(), unit: .lb) == "2.1 mi \u{00B7} 180 kcal \u{00B7} Apple Watch")
        #expect(ActivityText.facts(walk(kcal: nil, distanceM: nil), unit: .kg) == "Apple Watch")
        #expect(ActivityText.title(walk()) == "Walk")
        #expect(ActivityText.dateAndDuration(walk()).hasSuffix("\u{00B7} 45 min"))
    }

    @Test func theMeasuredLineSaysWhatWasMeasured() {
        #expect(ActivityText.measuredLine(walk(kcal: 412, avgHr: 128, maxHr: 162))
            == "Apple Watch measured 412 kcal \u{00B7} avg 128 bpm \u{00B7} max 162 bpm")
        #expect(ActivityText.measuredLine(walk(kcal: nil, maxHr: nil)) == "Apple Watch measured avg 102 bpm")
        #expect(ActivityText.measuredLine(walk(kcal: nil, avgHr: nil, maxHr: nil)) == nil)
    }

    @Test func theWeeksMeasuredCaloriesCountOnlyThisWeek() {
        let lastWeek = walk(start: start.addingTimeInterval(-8 * 86_400), kcal: 300)
        #expect(ActivityText.weekKcal([walk(), lastWeek], containing: start.addingTimeInterval(86_400)) == 180)
        #expect(ActivityText.otherKcalLine(1_240) == "+ \(1_240.formatted()) kcal from other activities (measured)")
    }

    @Test func todaysLineHasZerosBeforeAnyData() {
        let day = ActivityDay(day: "2026-09-26", steps: 4_210, moveKcal: 210.4, exerciseMin: 18, standH: 6)
        #expect(ActivityText.todayLine(day) == "\(4_210.formatted()) steps \u{00B7} 210 kcal \u{00B7} 18 min exercise")
        #expect(ActivityText.todayLine(nil) == "0 steps \u{00B7} 0 kcal \u{00B7} 0 min exercise")
        #expect(ActivityText.dayLine(day) == ActivityText.todayLine(day) + " \u{00B7} 6 h stand")
    }

    @Test func everySymbolExists() {
        for kind in OutsideWorkoutKind.allCases { #expect(UIImage(systemName: kind.symbol) != nil, "\(kind)") }
        #expect(UIImage(systemName: "figure.walk.motion") != nil)
        #expect(UIImage(systemName: "applewatch") != nil)
    }
}
