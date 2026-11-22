import Foundation

/// What a GymRollins workout shows as measured (plan 40, spec §5.3): one pure rule, so the detail, the saved snapshot
/// and the tests agree.
/// - Time and calories: the GymRollins watch app's copy, then a recording attached by plan 39's rule 6, then the app's
///   own estimate. A copy the phone wrote is never measured (decision 8): it holds that estimate.
/// - Heart rate: the workout's readings, whatever recorded them (decision 9), else the attached recording's own
///   average and maximum.
/// - Effort: a rating in Health (made in Fitness or here), then the app's own rating, then the Apple Watch's estimate
///   (decision 10).
public enum WorkoutMeasuredRules {
    /// The post-workout chart's span after the end, as Fitness draws it.
    public static let postWindow: TimeInterval = 180
    /// The stored post-workout heart rate is the reading closest to this long after the end: a steadier recovery
    /// measure than the last reading, which the chart's caption shows.
    public static let postMark: TimeInterval = 120

    // swiftlint:disable:next function_parameter_count
    public static func summary(start: Date, end: Date, appDuration: TimeInterval,
                               measurements: WorkoutMeasurements?, attached: HealthActivity?,
                               estimateKcal: Int?, appEffort: Effort?) -> MeasuredSummary {
        let health = measurements ?? WorkoutMeasurements.none
        let readings = health.heartRate.within(start, end)
        let post = health.postWorkout.within(end, end.addingTimeInterval(postWindow))
        let (source, time, measured, active, total) = timeAndCalories(health, attached: attached, appDuration: appDuration)
        return MeasuredSummary(
            source: source, workoutTime: time, measuredDuration: measured, activeKcal: active, totalKcal: total,
            estimatedKcal: source == .estimate ? estimateKcal : nil,
            avgHr: readings.isEmpty ? attached?.avgHr : readings.averageBpm,
            maxHr: readings.isEmpty ? attached?.maxHr : readings.maximumBpm,
            heartRate: readings, postWorkout: post, lastPostHr: post.last.flatMap { whole($0.bpm) },
            postHr: closest(to: end.addingTimeInterval(postMark), in: post),
            effort: effort(health: health.effort, app: appEffort))
    }

    /// The first that has them: the watch copy, the attached recording, the app.
    private static func timeAndCalories(_ health: WorkoutMeasurements, attached: HealthActivity?,
                                        appDuration: TimeInterval)
        -> (MeasuredSummary.Source, TimeInterval, TimeInterval?, Double?, Double?) {
        if health.recordedBy == .watch {
            return (.watch, health.duration ?? appDuration, health.duration, health.activeKcal, health.totalKcal)
        }
        if let attached {
            return (.attached(sourceName: attached.sourceName), attached.durationS, attached.durationS, attached.kcal, attached.totalKcal)
        }
        return (.estimate, appDuration, nil, nil, nil)
    }

    /// Health's rating, then the app's own, then Health's estimate.
    static func effort(health: Effort?, app: Effort?) -> Effort? {
        if let health, !health.estimated { return health }
        return app ?? health
    }

    /// The reading closest to `mark` (the earlier of two as close), in whole beats.
    static func closest(to mark: Date, in readings: [HeartRateReading]) -> Int? {
        readings.min { abs($0.date.timeIntervalSince(mark)) < abs($1.date.timeIntervalSince(mark)) }
            .flatMap { whole($0.bpm) }
    }

    /// Rounded to a whole beat; nil for NaN or infinity.
    static func whole(_ bpm: Double) -> Int? { Int(exactly: bpm.rounded()) }
}

extension Array where Element == HeartRateReading {
    /// The real readings (finite, above zero) from `start` through `end`, oldest first; none when `end` is before
    /// `start`.
    func within(_ start: Date, _ end: Date) -> [HeartRateReading] {
        filter { $0.bpm.isFinite && $0.bpm > 0 && $0.date >= start && $0.date <= end }.sorted { $0.date < $1.date }
    }

    /// The mean in whole beats; nil with no readings.
    var averageBpm: Int? {
        isEmpty ? nil : WorkoutMeasuredRules.whole(reduce(0) { $0 + $1.bpm } / Double(count))
    }

    /// The highest in whole beats; nil with no readings.
    var maximumBpm: Int? { map(\.bpm).max().flatMap(WorkoutMeasuredRules.whole) }
}
