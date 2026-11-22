import Foundation

/// What a GymRollins workout's detail shows from Apple Health (plan 40, spec §4 and §5.3), as
/// `WorkoutMeasuredRules.summary` decides it: who measured the time and calories, heart rate for the tiles and the
/// charts, and the effort. Worked out on the phone each time the detail opens; `snapshot(workoutId:at:)` is the part
/// that's saved and synced.
public struct MeasuredSummary: Equatable, Sendable {
    /// Who measured the time and calories: the GymRollins watch app, a recording attached by plan 39's rule 6 (its
    /// source as Health names it), or nobody (the app's estimate).
    public enum Source: Equatable, Sendable { case watch, attached(sourceName: String), estimate }

    public let source: Source
    /// The watch copy's or the attached recording's duration, else the app's own.
    public let workoutTime: TimeInterval
    /// Nil when `source` is `.estimate`.
    public let activeKcal: Double?
    /// Nil when `source` is `.estimate`, or when the recording has no resting energy.
    public let totalKcal: Double?
    /// The app's estimate; non-nil only when `source` is `.estimate`.
    public let estimatedKcal: Int?
    public let avgHr: Int?
    public let maxHr: Int?
    /// The workout's readings, for the Heart Rate chart.
    public let heartRate: [HeartRateReading]
    /// The 3 minutes after the end, for the Post-Workout Heart Rate chart.
    public let postWorkout: [HeartRateReading]
    /// The post-workout chart's caption: its last reading.
    public let lastPostHr: Int?
    /// The reading closest to `WorkoutMeasuredRules.postMark` after the end: what's stored.
    public let postHr: Int?
    public let effort: Effort?
    /// What Health measured as the duration: nil for an estimate, and for a watch copy that has no duration (then
    /// `workoutTime` is the app's own and isn't saved as measured).
    private let measuredDuration: TimeInterval?

    public init(source: Source, workoutTime: TimeInterval, activeKcal: Double?, totalKcal: Double?,
                estimatedKcal: Int?, avgHr: Int?, maxHr: Int?, heartRate: [HeartRateReading],
                postWorkout: [HeartRateReading], lastPostHr: Int?, postHr: Int?, effort: Effort?) {
        self.init(source: source, workoutTime: workoutTime, measuredDuration: source == .estimate ? nil : workoutTime,
                  activeKcal: activeKcal, totalKcal: totalKcal, estimatedKcal: estimatedKcal, avgHr: avgHr,
                  maxHr: maxHr, heartRate: heartRate, postWorkout: postWorkout, lastPostHr: lastPostHr,
                  postHr: postHr, effort: effort)
    }

    // swiftlint:disable:next function_parameter_count
    init(source: Source, workoutTime: TimeInterval, measuredDuration: TimeInterval?, activeKcal: Double?,
         totalKcal: Double?, estimatedKcal: Int?, avgHr: Int?, maxHr: Int?, heartRate: [HeartRateReading],
         postWorkout: [HeartRateReading], lastPostHr: Int?, postHr: Int?, effort: Effort?) {
        self.measuredDuration = measuredDuration
        self.source = source
        self.workoutTime = workoutTime
        self.activeKcal = activeKcal
        self.totalKcal = totalKcal
        self.estimatedKcal = estimatedKcal
        self.avgHr = avgHr
        self.maxHr = maxHr
        self.heartRate = heartRate
        self.postWorkout = postWorkout
        self.lastPostHr = lastPostHr
        self.postHr = postHr
        self.effort = effort
    }

    /// The row to save; nil when there is nothing measured, no heart rate and no effort. The app's own estimate and
    /// duration are never saved as measured: an estimated summary keeps only its heart rate and effort.
    /// The snapshot is all or nothing: if `isValid` fails, the whole row is dropped, not just the bad value. Plan 39's
    /// limits already keep an attached recording's values within `MeasurementLimits`.
    public func snapshot(workoutId: UUID, at date: Date) -> MeasurementSnapshot? {
        let recordedBy: MeasurementSnapshot.RecordedBy? = switch source {
        case .watch: .watch
        case .attached: .appleWorkout
        case .estimate: nil
        }
        guard recordedBy != nil || avgHr != nil || maxHr != nil || postHr != nil || effort != nil else { return nil }
        return MeasurementSnapshot(workoutId: workoutId, recordedBy: recordedBy,
                                   durationS: measuredDuration, activeKcal: activeKcal,
                                   totalKcal: totalKcal, avgHr: avgHr, maxHr: maxHr, postHr: postHr,
                                   effort: effort?.score, effortEstimated: effort?.estimated ?? false,
                                   clientUpdatedAt: date)
    }
}
