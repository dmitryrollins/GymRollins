import Foundation
import Testing
@testable import GymCore

@Suite struct WorkoutSummaryTests {
    @Test func summarizesDurationSetsVolumeAndRecords() {
        let start = Date(timeIntervalSince1970: 0)
        let workout = Workout(startedAt: start, endedAt: start.addingTimeInterval(3_520), pausedSeconds: 40,
                              name: "Push + Biceps", entries: [
            WorkoutEntry(exerciseId: "bench", sets: [
                WorkoutSet(weightKg: 20, reps: 10, done: true, warmup: true),
                WorkoutSet(weightKg: 68.039, reps: 10, done: true),
                WorkoutSet(weightKg: 68.039, reps: 10, done: true),
            ]),
        ])
        let prior = ["bench": ExerciseBests(e1RMKg: 81.65, repsAtWeight: [68_039: 6], volumeKg: 1_224.7)]
        let summary = WorkoutSummary(workout: workout, previousBests: prior)
        #expect(summary.durationSeconds == 3_480)
        #expect(summary.workingSets == 2)
        #expect(abs(summary.volumeKg - 1_360.78) < 0.01)
        #expect(summary.records.map(\.kind).contains(.e1RM))
    }
}
