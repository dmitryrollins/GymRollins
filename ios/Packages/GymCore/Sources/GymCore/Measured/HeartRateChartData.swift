import Foundation

/// The shape of a heart-rate chart on the workout detail (plan 40, spec §4): the readings it draws, its x-axis span
/// and three time ticks, the maximum labelled top-right and the average caption. Swift Charts draws it; this decides
/// what it draws.
public struct HeartRateChartData: Equatable, Sendable {
    /// The most points a chart draws. A long Watch workout holds thousands of readings (one every few seconds); a dot
    /// for each costs Swift Charts a view per reading and looks no different at 140 pt tall.
    public static let drawnLimit = 240

    /// Only those inside `start...end`, oldest first: every one, for the maximum and the average.
    public let readings: [HeartRateReading]
    /// What the chart draws: `readings` while there are at most `drawnLimit`, else the first, the last, and the
    /// highest reading in each equal slice of time between them, so a peak is never dropped.
    public let drawn: [HeartRateReading]
    public let start: Date
    public let end: Date
    /// The workout chart: start, middle, end. The post-workout chart: the end, 1 MIN, 2 MIN.
    public let ticks: [Date]
    public let maxBpm: Int?
    public let avgBpm: Int?

    /// The Heart Rate chart: the workout's start to its end.
    public static func workout(_ readings: [HeartRateReading], start: Date, end: Date) -> HeartRateChartData {
        let end = max(start, end)
        let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        return HeartRateChartData(readings.within(start, end), start: start, end: end, ticks: [start, middle, end])
    }

    /// The Post-Workout Heart Rate chart: the end to `WorkoutMeasuredRules.postWindow` after it.
    public static func postWorkout(_ readings: [HeartRateReading], end: Date) -> HeartRateChartData {
        let last = end.addingTimeInterval(WorkoutMeasuredRules.postWindow)
        return HeartRateChartData(readings.within(end, last), start: end, end: last,
                                  ticks: [end, end.addingTimeInterval(60), end.addingTimeInterval(120)])
    }

    private init(_ readings: [HeartRateReading], start: Date, end: Date, ticks: [Date]) {
        self.readings = readings
        drawn = Self.thinned(readings, limit: Self.drawnLimit)
        self.start = start
        self.end = end
        self.ticks = ticks
        maxBpm = readings.maximumBpm
        avgBpm = readings.averageBpm
    }

    /// `readings` (oldest first) cut to at most `limit`: the first and the last, and between them `limit - 2` equal
    /// slices of their time span, each drawn as its highest reading (the earliest of equals). Readings all at one
    /// instant fall in one slice.
    static func thinned(_ readings: [HeartRateReading], limit: Int) -> [HeartRateReading] {
        guard readings.count > limit, limit > 2, let first = readings.first, let last = readings.last else {
            return readings
        }
        let slices = limit - 2
        let span = last.date.timeIntervalSince(first.date)
        let slice = { (reading: HeartRateReading) -> Int in
            guard span > 0 else { return 0 }
            return min(slices - 1, Int(reading.date.timeIntervalSince(first.date) / span * Double(slices)))
        }
        let peaks = Dictionary(grouping: readings.dropFirst().dropLast(), by: slice)
            .sorted { $0.key < $1.key }
            .compactMap { $0.value.max { $0.bpm < $1.bpm } }
        return [first] + peaks + [last]
    }
}
