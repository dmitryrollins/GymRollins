import Accessibility
import Foundation
import GymCore
import Testing
@testable import GymRollins

/// Plan 40, spec §4: the heart-rate charts' audio graph. Seconds from the chart's start on x, beats per minute on y,
/// over the points the chart draws. Sat 19 Sep 2026, 18:00 UTC, a 3,500 s workout.
@Suite struct HeartRateChartDescriptorTests {
    private let start = ISO8601DateFormatter().date(from: "2026-09-19T18:00:00Z")!

    /// Readings every `every` seconds from 2 minutes in.
    private func descriptor(_ bpm: [Double], every: TimeInterval = 300, span: TimeInterval = 3_500) -> AXChartDescriptor {
        let readings = bpm.enumerated().map { index, bpm in
            HeartRateReading(date: start.addingTimeInterval(120 + Double(index) * every), bpm: bpm)
        }
        let data = HeartRateChartData.workout(readings, start: start, end: start.addingTimeInterval(span))
        return HeartRateChartDescriptor(title: "Heart Rate", summary: "Heart rate", data: data).makeChartDescriptor()
    }

    @Test func theAxesSpanTheWorkoutAndItsReadings() throws {
        let chart = descriptor([110, 118, 124, 131, 136, 162, 140, 129, 122, 118, 126, 120])
        let x = try #require(chart.xAxis as? AXNumericDataAxisDescriptor)
        #expect(x.range == 0...3_500)
        #expect(chart.yAxis?.range == 110...162)
        #expect(chart.series.count == 1)
        #expect(chart.series.first?.dataPoints.count == 12)
        #expect(chart.title == "Heart Rate")
    }

    @Test func equalReadingsStillGiveTheHeartRateAxisARange() throws {
        let range = try #require(descriptor([120, 120, 120]).yAxis?.range)
        #expect(range.lowerBound == 120)
        #expect(range.upperBound > range.lowerBound)
    }

    @Test func oneReadingIsOnePoint() throws {
        let chart = descriptor([131])
        let range = try #require(chart.yAxis?.range)
        #expect(range.lowerBound == 131 && range.upperBound > 131)
        #expect(chart.series.first?.dataPoints.count == 1)
    }

    /// A 2 h workout read every 1.44 s: the audio graph plays the points the chart draws, not all 5,000.
    @Test func aLongWorkoutPlaysItsDrawnPoints() throws {
        let bpm = (0..<5_000).map { 100 + Double($0 % 60) }
        let chart = descriptor(bpm, every: 1.44, span: 7_400)
        let points = try #require(chart.series.first?.dataPoints)
        #expect(points.count <= HeartRateChartData.drawnLimit)
        #expect(chart.yAxis?.range.upperBound == 159)
    }
}
