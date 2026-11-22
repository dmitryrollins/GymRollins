#if DEBUG
import Foundation
import GymCore
import GymData
import GymHealth

/// `-fakeHealth`'s watch copy (plan 40): what the GymRollins watch app would have written to Health for
/// `-seedHistory`'s Sat 19 Sep workout, the one plan 39's Apple Watch strength recording attaches to. Made-up values
/// shaped like a strength session: 412 of 489 kcal, a dozen readings averaging 128 (the highest 162), and three in the
/// 3 minutes after it, the last 124. No effort, so the Effort card offers Add Effort.
@MainActor
enum DebugMeasuredSeed {
    /// Every `readingEvery` seconds from `firstReading` into the workout (the last at 57:00, inside its 58:20).
    static let workoutBpm: [Double] = [110, 118, 124, 131, 136, 162, 140, 129, 122, 118, 126, 120]
    static let firstReading: TimeInterval = 120
    static let readingEvery: TimeInterval = 300
    /// Seconds after the end, and the reading.
    static let postWorkout: [(seconds: TimeInterval, bpm: Double)] = [(30, 141), (90, 132), (170, 124)]
    static let activeKcal: Double = 412
    static let totalKcal: Double = 489

    /// The copy keyed by the seeded workout's id (a new one each launch); empty without `-seedHistory`.
    static func watchCopies(in workouts: WorkoutRepository, now: Date) -> [UUID: WorkoutMeasurements] {
        guard let workout = seededWorkout(in: workouts, now: now), let end = workout.endedAt else { return [:] }
        let readings = workoutBpm.enumerated().map { index, bpm in
            HeartRateReading(date: workout.startedAt.addingTimeInterval(firstReading + Double(index) * readingEvery),
                             bpm: bpm)
        }
        let after = postWorkout.map { HeartRateReading(date: end.addingTimeInterval($0.seconds), bpm: $0.bpm) }
        let duration = max(0, end.timeIntervalSince(workout.startedAt) - workout.pausedSeconds)
        return [workout.id: WorkoutMeasurements(recordedBy: .watch, duration: duration, activeKcal: activeKcal,
                                                totalKcal: totalKcal, heartRate: readings, postWorkout: after,
                                                effort: nil)]
    }

    /// `-seedHistory`'s finished workout around plan 39's strength recording; nil when there is none.
    private static func seededWorkout(in workouts: WorkoutRepository, now: Date) -> Workout? {
        guard let recording = FakeHealthStore.uiTestOutsideWorkouts(now: now)
            .first(where: { $0.activity.id == FakeHealthStore.uiTestStrengthId })?.activity else { return nil }
        do {
            return try workouts.recent(limit: 20).first { workout in
                guard let end = workout.endedAt else { return false }
                return workout.startedAt <= recording.startedAt && recording.endedAt <= end
            }
        } catch {
            AppEnvironment.log.error("Find the seeded workout failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
#endif
