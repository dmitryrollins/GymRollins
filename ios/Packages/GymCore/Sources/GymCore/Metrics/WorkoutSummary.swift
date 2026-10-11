import Foundation

public struct WorkoutSummary: Sendable, Equatable {
    public let durationSeconds: TimeInterval
    public let workingSets: Int
    public let volumeKg: Double
    public let records: [PersonalRecord]

    public init(workout: Workout, previousBests: [String: ExerciseBests]) {
        let end = workout.endedAt ?? workout.startedAt
        durationSeconds = max(0, end.timeIntervalSince(workout.startedAt) - workout.pausedSeconds)
        workingSets = WorkoutMetrics.workingSetCount(workout)
        volumeKg = WorkoutMetrics.volumeKg(workout)
        records = RecordDetector.records(for: workout, previous: previousBests)
    }
}
