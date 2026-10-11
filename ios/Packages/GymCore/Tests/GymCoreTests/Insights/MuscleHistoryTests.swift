import Foundation
import Testing
@testable import GymCore

struct MuscleHistoryTests {
    typealias F = InsightsFixture

    @Test func recentSessionsForAGroupNewestFirstWithHardSetsOnly() {
        let workouts = [
            F.workout("2026-09-19T18:00:00Z", [("0025", F.sets(1, warmup: true) + F.sets(3))]),
            F.workout("2026-09-24T18:00:00Z", [("0313", F.sets(2)), ("0198", F.sets(3))]),
            F.workout("2026-09-25T18:00:00Z", [("0662", F.sets(2, kg: 0, reps: 15))]),
        ]
        let chest = MuscleHistory.recent(group: .chest, workouts: workouts, exercise: F.lookup)
        #expect(chest.map(\.exerciseId) == ["0662", "0025"])
        #expect(chest[1].sets.count == 3)
        #expect(chest.allSatisfy { $0.isPrimary })
        let biceps = MuscleHistory.recent(group: .biceps, workouts: workouts, exercise: F.lookup)
        #expect(biceps.map(\.exerciseId) == ["0313", "0198"])
        #expect(biceps.map(\.isPrimary) == [true, false])
        #expect(MuscleHistory.recent(group: .biceps, workouts: workouts, exercise: F.lookup, limit: 1).count == 1)
        #expect(MuscleHistory.recent(group: .quads, workouts: workouts, exercise: F.lookup).isEmpty)
    }

    @Test func limitedMusclesFromTheLimitsNote() {
        #expect(LimitedMuscles.from(limits: "Knee: no leg loading until ~26 Oct 2026") == MuscleGroup.legs)
        #expect(LimitedMuscles.from(limits: "left KNEES sore") == MuscleGroup.legs)
        #expect(LimitedMuscles.from(limits: "skip legs for a month") == MuscleGroup.legs)
        #expect(LimitedMuscles.from(limits: "").isEmpty)
        #expect(LimitedMuscles.from(limits: "legacy note: elbow ok").isEmpty)
        #expect(LimitedMuscles.from(limits: "shoulder impingement").isEmpty)
    }
}
