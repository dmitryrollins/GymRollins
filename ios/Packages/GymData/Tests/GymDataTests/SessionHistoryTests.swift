import Foundation
import GymCore
import Testing
@testable import GymData

@Suite struct SessionHistoryTests {
    @Test func usesWorkingSetsAtTopWeight() throws {
        let entry = WorkoutEntry(exerciseId: "0025", sets: [
            WorkoutSet(weightKg: 20, reps: 10, done: true, warmup: true),
            WorkoutSet(weightKg: 52.16, reps: 8, done: true),
            WorkoutSet(weightKg: 58.97, reps: 6, done: true),
            WorkoutSet(weightKg: 58.97, reps: 6, done: true),
            WorkoutSet(weightKg: 58.97, reps: 6, done: false),
        ])
        let result = try #require(SessionHistory.result(for: entry, date: .now))
        #expect(result.weightKg == 58.97)
        #expect(result.reps == [6, 6])
        #expect(result.rir.isEmpty) // nothing rated
    }

    @Test func carriesRatedRepsInReserveParallelToReps() throws {
        let entry = WorkoutEntry(exerciseId: "0025", sets: [
            WorkoutSet(weightKg: 20, reps: 10, done: true, warmup: true, rir: 5),
            WorkoutSet(weightKg: 58.97, reps: 10, done: true, rir: 3),
            WorkoutSet(weightKg: 58.97, reps: 9, done: true),
            WorkoutSet(weightKg: 58.97, reps: 8, done: true, rir: 1),
        ])
        let result = try #require(SessionHistory.result(for: entry, date: .now))
        #expect(result.reps == [10, 9, 8])
        #expect(result.rir == [3, nil, 1])
    }

    @Test func nilWithoutWorkingSets() {
        let entry = WorkoutEntry(exerciseId: "x", sets: [WorkoutSet(weightKg: 20, reps: 10, done: true, warmup: true)])
        #expect(SessionHistory.result(for: entry, date: .now) == nil)
    }
}
