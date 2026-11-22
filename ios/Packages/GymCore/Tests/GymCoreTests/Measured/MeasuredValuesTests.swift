import Foundation
import Testing
@testable import GymCore

/// Plan 40: Apple's effort scale and words, a workout's effort, and what Health holds for a GymRollins workout.
@Suite struct MeasuredValuesTests {
    private let start = ISO8601DateFormatter().date(from: "2026-09-19T18:00:00Z")!

    @Test(arguments: [
        (1, WorkoutEffortLevel.easy), (3, .easy), (4, .moderate), (6, .moderate), (7, .hard), (8, .hard),
        (9, .allOut), (10, .allOut),
    ])
    func aScoreHasApplesWord(score: Int, level: WorkoutEffortLevel) throws {
        #expect(WorkoutEffortLevel.level(for: score) == level)
        #expect(try #require(Effort(score: score, estimated: false)).level == level)
    }

    @Test func theWordsAreFitnesss() {
        #expect(WorkoutEffortLevel.allCases.map(\.title) == ["Easy", "Moderate", "Hard", "All Out"])
    }

    @Test func aScoreOutsideOneToTenIsNoEffort() {
        #expect(Effort.range == 1...10)
        #expect(WorkoutEffortLevel.level(for: 0) == nil && WorkoutEffortLevel.level(for: 11) == nil)
        #expect(Effort(score: 0, estimated: false) == nil)
        #expect(Effort(score: 11, estimated: true) == nil)
        let estimate = Effort(score: 5, estimated: true)
        #expect(estimate?.estimated == true && estimate?.level == .moderate)
    }

    @Test func measurementsKeepTheirReadingsOldestFirst() {
        let early = HeartRateReading(date: start.addingTimeInterval(60), bpm: 110)
        let late = HeartRateReading(date: start.addingTimeInterval(600), bpm: 140)
        let measured = WorkoutMeasurements(recordedBy: .watch, duration: 3_500, activeKcal: 412, totalKcal: 489,
                                           heartRate: [late, early], postWorkout: [late, early], effort: nil)
        #expect(measured.heartRate == [early, late])
        #expect(measured.postWorkout == [early, late])
        let none = WorkoutMeasurements.none
        #expect(none.recordedBy == nil && none.duration == nil && none.activeKcal == nil && none.totalKcal == nil)
        #expect(none.heartRate.isEmpty && none.postWorkout.isEmpty && none.effort == nil)
    }

    @Test func aReadingRoundTripsThroughJSON() throws {
        let reading = HeartRateReading(date: start, bpm: 128.5)
        let back = try JSONDecoder().decode(HeartRateReading.self, from: JSONEncoder().encode(reading))
        #expect(back == reading)
    }
}
