import Foundation
import GymCore
import GymHealth
import Testing
@testable import GymRollins

/// Plan 40's app tests: a workout shaped like `-seedHistory`'s Sat 19 Sep one (18:00–18:58:20 UTC), what the
/// GymRollins watch app wrote to Health for it, and an environment on an in-memory store with a `FakeHealthStore` the
/// test holds. Made-up values.
@MainActor
enum MeasuredFixture {
    static let now = ISO8601DateFormatter().date(from: "2026-09-26T09:00:00Z")!
    static let start = ISO8601DateFormatter().date(from: "2026-09-19T18:00:00Z")!
    static let workoutId = UUID(uuidString: "00000000-0000-4000-8000-0000000000b1")!

    /// 58:20 of bench, three working sets. Plan 39's strength recording (18:02–18:55) attaches to it.
    static func workout(id: UUID = workoutId, start: Date = start) -> Workout {
        Workout(id: id, startedAt: start, endedAt: start.addingTimeInterval(3_500), name: "Push + Biceps",
                entries: [WorkoutEntry(exerciseId: "0025", sets: (0..<3).map { _ in
                    WorkoutSet(weightKg: 59, reps: 10, done: true, completedAt: start)
                })])
    }

    /// The watch app's copy: 412 of 489 kcal, two readings (average 128, maximum 136) and one 2 minutes after it.
    static func watchCopy(start: Date = start, effort: Effort? = nil) -> WorkoutMeasurements {
        WorkoutMeasurements(recordedBy: .watch, duration: 3_500, activeKcal: 412, totalKcal: 489,
                            heartRate: [HeartRateReading(date: start.addingTimeInterval(600), bpm: 120),
                                        HeartRateReading(date: start.addingTimeInterval(1_800), bpm: 136)],
                            postWorkout: [HeartRateReading(date: start.addingTimeInterval(3_620), bpm: 124)],
                            effort: effort)
    }

    /// `-uiTesting` at `now` (Health's state in its throwaway suite) on `store`, with `workout()` saved finished unless
    /// `saved` is false, and Health turned on (which asks for every type) unless `healthOn` is false. Each environment
    /// has its own defaults suite, so a one-time flag (Task 13's backfill) never leaks between tests running together.
    static func environment(_ store: FakeHealthStore, healthOn: Bool = true,
                            saved: Bool = true) async throws -> AppEnvironment {
        let defaults = try #require(UserDefaults(suiteName: "MeasuredFixture.\(UUID())"))
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow",
                                                                       "2026-09-26T09:00:00Z"]),
                                     defaults: defaults, healthStore: store)
        if saved { try env.workouts.save(workout()) }
        if healthOn { #expect(await env.health.enable()) }
        return env
    }
}
