import Foundation
import Testing
@testable import GymCore

@Suite struct WorkoutMetricsTests {
    private let entry = WorkoutEntry(exerciseId: "bench", sets: [
        WorkoutSet(weightKg: 20, reps: 10, done: true, warmup: true),
        WorkoutSet(weightKg: 60, reps: 10, done: true),
        WorkoutSet(weightKg: 60, reps: 8, done: true),
        WorkoutSet(weightKg: 60, reps: 8, done: false),
    ])
    private let dumbbells = WorkoutEntry(exerciseId: "hammer", sets: [
        WorkoutSet(weightKg: 10, reps: 10, done: true, multiplier: 2),
    ])

    @Test func workingSetsExcludeWarmupsAndUndone() {
        #expect(WorkoutMetrics.workingSets(entry).count == 2)
    }

    @Test func volumeUsesMultiplier() {
        let w = Workout(startedAt: .now, name: "Push", entries: [entry, dumbbells])
        let set1: Double = 60 * 10
        let set2: Double = 60 * 8
        let dumbbellSet: Double = 10 * 10 * 2
        let expected: Double = set1 + set2 + dumbbellSet
        #expect(WorkoutMetrics.volumeKg(w) == expected)
    }

    @Test func bestE1RMPicksHighest() throws {
        let best = try #require(WorkoutMetrics.bestE1RM(entry))
        #expect(abs(best - 80) < 0.001) // 60 x 10 epley = 80
    }

    @Test func completedSetCount() {
        let w = Workout(startedAt: .now, name: "Push", entries: [entry, dumbbells])
        #expect(WorkoutMetrics.workingSetCount(w) == 3)
    }

    /// A heavy single does not hide a stronger rep set: 80 x 10 (~106.7) beats 100 x 1 (100).
    @Test func bestE1RMSetConsidersAllWorkingSets() throws {
        let mixed = WorkoutEntry(exerciseId: "bench", sets: [
            WorkoutSet(weightKg: 100, reps: 1, done: true),
            WorkoutSet(weightKg: 80, reps: 10, done: true)
        ])
        let best = try #require(WorkoutMetrics.bestE1RMSet(mixed))
        #expect(best.weightKg == 80 && best.reps == 10)
        #expect(abs((WorkoutMetrics.bestE1RM(mixed) ?? 0) - 106.667) < 0.001)
        #expect(WorkoutMetrics.bestE1RMSet(WorkoutEntry(exerciseId: "x")) == nil)
    }
}
