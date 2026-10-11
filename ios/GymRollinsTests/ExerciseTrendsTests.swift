import Foundation
import GymCore
import Testing
@testable import GymRollins

@Suite struct ExerciseTrendsTests {
    private let older = Date(timeIntervalSince1970: 1_000)
    private let newer = Date(timeIntervalSince1970: 2_000)

    /// 100 kg x 1 and 80 kg x 10 in one session: the trend point is ~106.7 kg (from 80 x 10), not
    /// the 100 kg a top-weight-only progression result would give.
    @Test func trendAndBestSetUseAllWorkingSets() throws {
        let sessions: [(date: Date, entry: WorkoutEntry)] = [
            (newer, WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: 90, reps: 3, done: true)])),
            (older, WorkoutEntry(exerciseId: "0025", sets: [
                WorkoutSet(weightKg: 100, reps: 1, done: true),
                WorkoutSet(weightKg: 80, reps: 10, done: true),
                WorkoutSet(weightKg: 120, reps: 5, done: false)
            ]))
        ]
        let points = ExerciseTrends.points(sessions)
        #expect(points.map(\.date) == [older, newer])
        #expect(abs(points[0].e1RMKg - 106.667) < 0.001)
        let best = try #require(ExerciseTrends.bestSet(sessions))
        #expect(best.weightKg == 80 && best.reps == 10)
    }
}
