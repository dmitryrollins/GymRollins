import Foundation

/// A workout another app saved to Apple Health (plan 39): a walk, run, ride or class that the Apple Watch's Workout
/// app, Strava or Fitness+ recorded. Read-only in GymRollins, and never a `Workout`: it stays out of PRs, strength
/// summaries, `log_workout`'s overlap check and the workout cap. `id` is the HealthKit workout's UUID, so two devices
/// importing the same workout write the same row. A deletion lives on the record and the sync row, not here.
public struct HealthActivity: Codable, Sendable, Equatable, Identifiable {
    /// Active time this long or longer counts toward the streak and the weekly goal (decision 5).
    public static let countingMinimum: TimeInterval = 600

    public let id: UUID
    /// An `OutsideWorkoutKind` slug, kept as text so a kind a newer app knows survives an older one.
    public let kind: String
    public let startedAt: Date
    public let endedAt: Date
    /// HealthKit's duration: pauses excluded.
    public let durationS: Double
    /// The workout's active energy statistic.
    public let kcal: Double?
    /// Walking/running, cycling or swimming distance, whichever the workout has.
    public let distanceM: Double?
    public let avgHr: Int?
    public let maxHr: Int?
    /// The source as Health shows it ("Apple Watch", "Strava").
    public let sourceName: String
    /// Recorded on an Apple Watch: the copy kept when two apps saved one session (rule 7).
    public let fromWatch: Bool

    public init(id: UUID, kind: String, startedAt: Date, endedAt: Date, durationS: Double, kcal: Double? = nil,
                distanceM: Double? = nil, avgHr: Int? = nil, maxHr: Int? = nil, sourceName: String,
                fromWatch: Bool = false) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationS = durationS
        self.kcal = kcal
        self.distanceM = distanceM
        self.avgHr = avgHr
        self.maxHr = maxHr
        self.sourceName = sourceName
        self.fromWatch = fromWatch
    }

    /// Whole minutes of active time.
    public var minutes: Int { Int(max(0, durationS) / 60) }

    /// Long enough to count toward the streak and the weekly goal, when it isn't attached to a GymRollins workout.
    public var countsAsWorkout: Bool { durationS >= Self.countingMinimum }
}
