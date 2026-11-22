import Foundation

/// The numbers saved and synced for a workout (plan 40, spec §6.1): one `workout_measurements` row. Heart-rate readings
/// never go in it (decision 11); `postHr` is the reading closest to 2 minutes after the end.
public struct MeasurementSnapshot: Equatable, Sendable {
    /// What measured the time and calories: the GymRollins watch app, or an attached recording (plan 39 rule 6). Nil
    /// when only heart rate or effort is known.
    public enum RecordedBy: String, Sendable, Codable { case watch, appleWorkout = "apple_workout" }

    public let workoutId: UUID
    public let recordedBy: RecordedBy?
    public let durationS: Double?
    public let activeKcal: Double?
    public let totalKcal: Double?
    public let avgHr: Int?
    public let maxHr: Int?
    public let postHr: Int?
    public let effort: Int?
    /// `effort` is the Apple Watch's estimate, not a rating.
    public let effortEstimated: Bool
    /// When the phone worked these numbers out: the sync's last-write-wins time.
    public let clientUpdatedAt: Date

    public init(workoutId: UUID, recordedBy: RecordedBy?, durationS: Double?, activeKcal: Double?, totalKcal: Double?,
                avgHr: Int?, maxHr: Int?, postHr: Int?, effort: Int?, effortEstimated: Bool, clientUpdatedAt: Date) {
        self.workoutId = workoutId
        self.recordedBy = recordedBy
        self.durationS = durationS
        self.activeKcal = activeKcal
        self.totalKcal = totalKcal
        self.avgHr = avgHr
        self.maxHr = maxHr
        self.postHr = postHr
        self.effort = effort
        self.effortEstimated = effortEstimated
        self.clientUpdatedAt = clientUpdatedAt
    }

    /// Every field but `clientUpdatedAt` equal: a re-read that changed nothing isn't saved or synced again.
    public func sameNumbers(as other: MeasurementSnapshot) -> Bool {
        workoutId == other.workoutId && recordedBy == other.recordedBy && durationS == other.durationS
            && activeKcal == other.activeKcal && totalKcal == other.totalKcal && avgHr == other.avgHr
            && maxHr == other.maxHr && postHr == other.postHr && effort == other.effort
            && effortEstimated == other.effortEstimated
    }

    /// Inside `MeasurementLimits` (every non-nil value in range): a row outside them would be refused when it syncs,
    /// so it isn't saved.
    public var isValid: Bool {
        Self.fits(durationS, MeasurementLimits.durationS) && Self.fits(activeKcal, MeasurementLimits.kcal)
            && Self.fits(totalKcal, MeasurementLimits.kcal)
            && [avgHr, maxHr, postHr].allSatisfy { Self.fits($0, MeasurementLimits.heartRate) }
            && Self.fits(effort, MeasurementLimits.effort)
    }

    /// Nil fits; NaN never does (no range contains it).
    private static func fits<Value: Comparable>(_ value: Value?, _ range: ClosedRange<Value>) -> Bool {
        value.map(range.contains) ?? true
    }
}
