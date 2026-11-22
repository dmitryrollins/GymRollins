import Accessibility
import Charts
import GymCore
import SwiftUI

/// The workout detail's two heart-rate charts (spec §4), each only when Health has a reading for it: during the
/// workout, and the 3 minutes after it.
struct WorkoutHeartRateCharts: View {
    /// Both charts' data, built once per summary by the detail rather than on every body pass: a long workout holds
    /// thousands of readings to filter and thin.
    struct Model {
        let during: HeartRateChartData?
        let after: HeartRateChartData?
        let lastPostHr: Int?

        /// Nil when there's nothing to draw: a workout that doesn't end after it starts has no span to plot, or
        /// neither chart has a reading.
        init?(summary: MeasuredSummary, start: Date, end: Date) {
            guard end > start else { return nil }
            let during = HeartRateChartData.workout(summary.heartRate, start: start, end: end)
            let after = HeartRateChartData.postWorkout(summary.postWorkout, end: end)
            self.during = during.readings.isEmpty ? nil : during
            self.after = after.readings.isEmpty || summary.lastPostHr == nil ? nil : after
            lastPostHr = summary.lastPostHr
            guard self.during != nil || self.after != nil else { return nil }
        }
    }

    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let during = model.during {
                HeartRateChartCard(title: "Heart Rate", data: during,
                                   tickLabels: MeasuredText.tickLabels(during, postWorkout: false),
                                   caption: MeasuredText.averageCaption(during) ?? "", showsMaximum: true,
                                   summary: MeasuredText.chartSummary(during), identifier: "detail.heartRateChart")
            }
            if let after = model.after, let last = model.lastPostHr {
                HeartRateChartCard(title: "Post-Workout Heart Rate", data: after,
                                   tickLabels: MeasuredText.tickLabels(after, postWorkout: true),
                                   caption: MeasuredText.lastReadingCaption(last), showsMaximum: false,
                                   summary: MeasuredText.postChartSummary(after, last: last),
                                   identifier: "detail.postHeartRateChart")
            }
        }
    }
}

/// A heart-rate dot chart in Fitness' style: the readings as heart-rate-red points over the span, three time labels,
/// the maximum top-right (the workout chart), and the caption under it. One VoiceOver element with the summary and
/// Swift Charts' audio graph. The chart's height is set before the readings are known, so the card never jumps.
struct HeartRateChartCard: View {
    let title: String
    let data: HeartRateChartData
    let tickLabels: [String]
    let caption: String
    let showsMaximum: Bool
    let summary: String
    let identifier: String

    /// 140 pt at the default text size, growing with the time labels' caption style, so the larger labels at
    /// accessibility sizes don't squeeze the plot.
    @ScaledMetric(relativeTo: .caption) private var chartHeight: CGFloat = 140

    var body: some View {
        DetailSection(title: title, titleIdentifier: "\(identifier).title") {
            VStack(alignment: .leading, spacing: 8) {
                chart.frame(height: chartHeight)
                Text(caption)
                    .font(Theme.number(20)).foregroundStyle(Theme.Metric.heartRate)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)
            .accessibilityChartDescriptor(HeartRateChartDescriptor(title: title, summary: summary, data: data))
            .accessibilityIdentifier(identifier)
        }
    }

    /// The drawn points (at most `HeartRateChartData.drawnLimit`), indexed rather than keyed by date: two sources (the
    /// watch and a chest strap) can read at the same instant.
    private var chart: some View {
        Chart(Array(data.drawn.enumerated()), id: \.offset) { _, reading in
            PointMark(x: .value("Time", reading.date), y: .value("BPM", reading.bpm))
                .symbolSize(24)
                .foregroundStyle(Theme.Metric.heartRate)
        }
        .chartXScale(domain: data.start...data.end)
        .chartYScale(domain: yDomain)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: data.ticks) { value in
                AxisGridLine().foregroundStyle(Theme.divider)
                AxisValueLabel(anchor: anchor(at: value.index, of: value.count)) {
                    Text(label(at: value.index)).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsMaximum, let max = MeasuredText.maximumLabel(data) {
                Text(max).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// Room under the lowest dot, and over the highest a quarter of the plot (at least 15 BPM): the maximum's label
    /// sits there, and since it and the chart both scale with the caption style, it never covers a dot.
    private var yDomain: ClosedRange<Double> {
        let bpm = data.drawn.map(\.bpm)
        guard let low = bpm.min(), let high = bpm.max() else { return 40...200 }
        let bottom = low - 10
        return bottom...(high + max(15, (high - bottom) / 3))
    }

    /// Labels start at their ticks (Charts' default), as the post-workout chart's do: its plot runs a minute past
    /// "2 MIN". The workout chart's last tick is its end, on the plot's trailing edge, where a label after its tick
    /// would be dropped, so it ends at its tick, and the middle one is centred under its own, which keeps the three
    /// apart at accessibility sizes.
    private func anchor(at index: Int, of count: Int) -> UnitPoint? {
        guard index > 0, let last = data.ticks.last, last >= data.end else { return nil }
        return index == count - 1 ? .topTrailing : .top
    }

    private func label(at index: Int) -> String {
        tickLabels.indices.contains(index) ? tickLabels[index] : ""
    }
}

/// Swift Charts' audio graph for a heart-rate chart: seconds from the chart's start on x, beats per minute on y, over
/// the points the chart draws.
struct HeartRateChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let summary: String
    let data: HeartRateChartData

    func makeChartDescriptor() -> AXChartDescriptor {
        let span = max(1, data.end.timeIntervalSince(data.start))
        let bpm = data.drawn.map(\.bpm)
        let low = bpm.min() ?? 0
        let x = AXNumericDataAxisDescriptor(title: "Time", range: 0...span, gridlinePositions: []) { seconds in
            MeasuredText.spokenMinutesIn(seconds)
        }
        // One reading, or all equal, still gets an axis with some height.
        let y = AXNumericDataAxisDescriptor(title: "Heart rate", range: low...max(low + 1, bpm.max() ?? 1),
                                            gridlinePositions: []) { value in
            MeasuredText.spokenBpm(value)
        }
        let points = data.drawn.map { AXDataPoint(x: $0.date.timeIntervalSince(data.start), y: $0.bpm) }
        return AXChartDescriptor(title: title, summary: summary, xAxis: x, yAxis: y, additionalAxes: [],
                                 series: [AXDataSeriesDescriptor(name: title, isContinuous: false, dataPoints: points)])
    }
}
