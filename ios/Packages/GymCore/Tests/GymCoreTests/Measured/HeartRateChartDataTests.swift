import Foundation
import Testing
@testable import GymCore

/// Plan 40, spec §4: the two heart-rate charts' shape: which readings they draw, their ticks, maximum and average.
@Suite struct HeartRateChartDataTests {
    private let start = ISO8601DateFormatter().date(from: "2026-09-19T18:00:00Z")!
    private var end: Date { start.addingTimeInterval(3_500) }

    private func reading(_ date: Date, _ bpm: Double) -> HeartRateReading { HeartRateReading(date: date, bpm: bpm) }

    @Test func theWorkoutChartSpansTheWorkoutWithThreeTicks() {
        let inside = [reading(start.addingTimeInterval(600), 120), reading(start.addingTimeInterval(1_800), 162),
                      reading(end, 102)]
        let outside = [reading(start.addingTimeInterval(-1), 90), reading(end.addingTimeInterval(1), 140)]
        let chart = HeartRateChartData.workout(outside + inside, start: start, end: end)
        #expect(chart.readings == inside)
        #expect(chart.start == start && chart.end == end)
        #expect(chart.ticks == [start, start.addingTimeInterval(1_750), end])
        #expect(chart.maxBpm == 162)
        #expect(chart.avgBpm == 128)
    }

    @Test func thePostWorkoutChartIsThreeMinutesWithMinuteTicks() {
        let post = [reading(end.addingTimeInterval(30), 135), reading(end.addingTimeInterval(75), 126),
                    reading(end.addingTimeInterval(118), 124)]
        let chart = HeartRateChartData.postWorkout([reading(end.addingTimeInterval(181), 99)] + post, end: end)
        #expect(chart.readings == post)
        #expect(chart.start == end && chart.end == end.addingTimeInterval(180))
        #expect(chart.ticks == [end, end.addingTimeInterval(60), end.addingTimeInterval(120)])
        #expect(chart.maxBpm == 135)
        #expect(chart.avgBpm == 128, "128.33")
    }

    @Test func noReadingsMeansNoMaximumOrAverage() {
        let chart = HeartRateChartData.workout([], start: start, end: end)
        #expect(chart.readings.isEmpty && chart.maxBpm == nil && chart.avgBpm == nil)
        #expect(chart.ticks.count == 3)
        let post = HeartRateChartData.postWorkout([], end: end)
        #expect(post.maxBpm == nil && post.avgBpm == nil)
    }

    @Test func aWorkoutEndingBeforeItStartsHasNoSpan() {
        let chart = HeartRateChartData.workout([reading(start.addingTimeInterval(-30), 120)], start: start,
                                               end: start.addingTimeInterval(-60))
        #expect(chart.end == start)
        #expect(chart.ticks == [start, start, start])
        #expect(chart.readings.isEmpty)
    }

    // MARK: Drawn points

    /// A 2 h Watch workout read every ~1.4 s: drawn as at most `drawnLimit` points, each time bucket's highest, the
    /// first and last kept; the maximum and average still come from every reading.
    @Test func aLongWorkoutIsDrawnWithABoundedNumberOfPoints() {
        let long = start.addingTimeInterval(7_200)
        let bpm = (0..<5_000).map { $0 == 2_345 ? 187 : 100 + Double($0 % 60) }
        let readings = bpm.enumerated().map { reading(start.addingTimeInterval(Double($0.offset) * 1.44), $0.element) }
        let chart = HeartRateChartData.workout(readings, start: start, end: long)
        #expect(chart.readings.count == 5_000, "every reading is kept for the numbers")
        #expect(chart.drawn.count <= HeartRateChartData.drawnLimit)
        #expect(chart.drawn.count > HeartRateChartData.drawnLimit / 2, "the buckets are used, not thrown away")
        #expect(chart.drawn.first == readings.first && chart.drawn.last == readings.last)
        #expect(chart.drawn.contains { $0.bpm == 187 }, "the spike survives")
        #expect(chart.drawn.map(\.date) == chart.drawn.map(\.date).sorted(), "oldest first")
        #expect(chart.maxBpm == 187)
        #expect(chart.avgBpm == readings.averageBpm)
    }

    @Test func fewerReadingsThanTheLimitAreAllDrawn() {
        let readings = (0..<12).map { reading(start.addingTimeInterval(120 + Double($0) * 300), 110 + Double($0)) }
        let chart = HeartRateChartData.workout(readings, start: start, end: end)
        #expect(chart.drawn == chart.readings)
        #expect(chart.drawn.count == 12)
    }

    @Test func readingsAllAtOneInstantAreDrawnAsTheirFirstHighestAndLast() {
        let at = start.addingTimeInterval(60)
        let readings = (0..<500).map { reading(at, $0 == 250 ? 170 : 120) }
        let chart = HeartRateChartData.workout(readings, start: start, end: end)
        #expect(chart.drawn.count == 3)
        #expect(chart.drawn.contains { $0.bpm == 170 })
    }

    @Test func readingsThatArentRealNumbersAreNotDrawn() {
        let good = reading(start.addingTimeInterval(600), 120)
        let bad = [reading(start.addingTimeInterval(10), .nan), reading(start.addingTimeInterval(20), .infinity),
                   reading(start.addingTimeInterval(30), 0)]
        let chart = HeartRateChartData.workout(bad + [good], start: start, end: end)
        #expect(chart.readings == [good] && chart.maxBpm == 120 && chart.avgBpm == 120)
        let postGood = reading(end.addingTimeInterval(30), 130)
        let post = HeartRateChartData.postWorkout([reading(end.addingTimeInterval(5), .nan), postGood], end: end)
        #expect(post.readings == [postGood] && post.maxBpm == 130)
    }
}
