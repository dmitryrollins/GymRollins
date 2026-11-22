import Foundation

/// What Apple Health holds for one GymRollins workout (plan 40, spec §5.1), as `HealthStore.workoutMeasurements` reads
/// it. Time and calories come only from the GymRollins watch app's copy: the copy the phone wrote holds the app's own
/// estimate and is never read back as measured (decision 8). Heart rate is every reading in the span, whatever
/// recorded it (decision 9).
public struct WorkoutMeasurements: Equatable, Sendable {
    /// The GymRollins copy Health has: the watch app's recording, or the phone exporter's.
    public enum Copy: String, Sendable { case watch, phone }

    /// Nil: Health has no GymRollins copy of the workout (Health was off, or the export hasn't run yet).
    public let recordedBy: Copy?
    /// The watch copy's duration, pauses excluded. Nil otherwise.
    public let duration: TimeInterval?
    /// The watch copy's active energy. Nil otherwise.
    public let activeKcal: Double?
    /// The watch copy's active plus resting energy, Fitness' "Total". Nil otherwise, or without resting energy.
    public let totalKcal: Double?
    /// From the workout's start to its end, any source, oldest first.
    public let heartRate: [HeartRateReading]
    /// From the end to `WorkoutMeasuredRules.postWindow` after it, any source, oldest first.
    public let postWorkout: [HeartRateReading]
    /// The rating related to the copy, else the Apple Watch's estimate. Nil with no copy, or neither.
    public let effort: Effort?

    public init(recordedBy: Copy?, duration: TimeInterval?, activeKcal: Double?, totalKcal: Double?,
                heartRate: [HeartRateReading], postWorkout: [HeartRateReading], effort: Effort?) {
        self.recordedBy = recordedBy
        self.duration = duration
        self.activeKcal = activeKcal
        self.totalKcal = totalKcal
        self.heartRate = heartRate.sorted { $0.date < $1.date }
        self.postWorkout = postWorkout.sorted { $0.date < $1.date }
        self.effort = effort
    }

    /// Nothing in Health: no copy, no heart rate, no effort. Spell it `WorkoutMeasurements.none` where a
    /// `WorkoutMeasurements?` is expected: a bare `.none` there is `nil`.
    public static let none = WorkoutMeasurements(recordedBy: nil, duration: nil, activeKcal: nil, totalKcal: nil,
                                                 heartRate: [], postWorkout: [], effort: nil)
}
