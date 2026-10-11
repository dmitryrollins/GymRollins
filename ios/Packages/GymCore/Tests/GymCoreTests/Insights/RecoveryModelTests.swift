import Foundation
import Testing
@testable import GymCore

struct RecoveryModelTests {
    typealias F = InsightsFixture
    let now = F.date("2026-09-26T09:00:00Z")

    private func recovery(_ workouts: [Workout]) -> [MuscleGroup: MuscleRecovery] {
        Dictionary(uniqueKeysWithValues: RecoveryModel.compute(workouts: workouts, exercise: F.lookup, now: now)
            .map { ($0.group, $0) })
    }

    @Test func noHistoryIsFullyFresh() {
        let all = RecoveryModel.compute(workouts: [], exercise: F.lookup, now: now)
        #expect(all.map(\.group) == MuscleGroup.allCases)
        #expect(all.allSatisfy { $0.percent == 100 && $0.status == .fresh && $0.lastTrained == nil && $0.recoveredAt == nil })
    }

    @Test func recoveryHoursScaleWithLoad() {
        #expect(RecoveryModel.recoveryHours(load: 0.5) == 27)
        #expect(RecoveryModel.recoveryHours(load: 4) == 48)
        #expect(RecoveryModel.recoveryHours(load: 8) == 72)
        #expect(RecoveryModel.recoveryHours(load: 20) == 96)
    }

    @Test func singleSessionDecaysLinearly() {
        // 3 sets of bench ended 24 h ago: chest load 3 → f0 0.5, 42 h → remaining 0.5 × (1 − 24/42).
        let w = F.workout("2026-09-25T08:00:00Z", [("0025", F.sets(3))])
        let r = recovery([w])
        let chest = r[.chest]!
        #expect(chest.percent == 79) // 1 − 0.5 × 18/42 = 0.7857
        #expect(chest.status == .recovering)
        #expect(chest.lastTrained == F.date("2026-09-25T09:00:00Z"))
        #expect(chest.recoveredAt == F.date("2026-09-25T09:00:00Z").addingTimeInterval(42 * 3_600))
        // Triceps: load 1.5 → f0 0.25, 33 h → 0.25 × 9/33.
        #expect(r[.triceps]!.percent == 93)
        #expect(r[.triceps]!.status == .fresh)
        #expect(r[.biceps]!.percent == 100)
    }

    @Test func heavyVolumeFatiguesFullyAndTakesLonger() {
        let w = F.workout("2026-09-26T07:00:00Z", [("0025", F.sets(12))]) // ended 1 h ago
        let chest = recovery([w])[.chest]!
        #expect(chest.percent == 1) // 1 − 1 × (1 − 1/96)
        #expect(chest.status == .fatigued)
        #expect(chest.recoveredAt == F.date("2026-09-26T08:00:00Z").addingTimeInterval(96 * 3_600))
    }

    @Test func fullyRecoveredAfterTheWindow() {
        let w = F.workout("2026-09-22T08:00:00Z", [("0025", F.sets(4))]) // 4 sets → 48 h, ended 96 h ago
        let chest = recovery([w])[.chest]!
        #expect(chest.percent == 100)
        #expect(chest.recoveredAt == nil)
        #expect(chest.lastTrained == F.date("2026-09-22T09:00:00Z"))
    }

    @Test func sessionsStackAndCapAtFullyFatigued() {
        let a = F.workout("2026-09-25T08:00:00Z", [("0025", F.sets(3))])
        let b = F.workout("2026-09-26T07:00:00Z", [("0662", F.sets(3, kg: 0, reps: 20))]) // push-ups, 1 h ago
        let chest = recovery([a, b])[.chest]!
        // a: 0.5 × 18/42 = 0.2143; b: 0.5 × 41/42 = 0.4881 → 0.7024 fatigued.
        #expect(chest.percent == 30)
        #expect(chest.lastTrained == F.date("2026-09-26T08:00:00Z"))
        let many = (0..<4).map { _ in F.workout("2026-09-26T07:00:00Z", [("0025", F.sets(6))]) }
        #expect(recovery(many)[.chest]!.percent == 0)
    }

    @Test func bodyweightSetsLoadLikeAnyOther() {
        let w = F.workout("2026-09-25T08:00:00Z", [("0662", F.sets(3, kg: 0, reps: 20))])
        #expect(recovery([w])[.chest]!.percent == 79)
    }

    @Test func cardioWarmupsAndFutureWorkoutsDontFatigue() {
        let cardio = F.workout("2026-09-26T07:00:00Z", [("run", F.sets(1, reps: 1, sec: 1_800))])
        let warm = F.workout("2026-09-26T07:00:00Z", [("0025", F.sets(4, warmup: true))])
        let future = F.workout("2026-09-27T07:00:00Z", [("0025", F.sets(4))])
        let r = recovery([cardio, warm, future])
        #expect(r.values.allSatisfy { $0.percent == 100 && $0.lastTrained == nil })
    }

    @Test func lowEffortSetsFatigueLess() {
        let hard = F.workout("2026-09-26T07:00:00Z", [("0025", F.sets(3, rir: 0))])
        let easy = F.workout("2026-09-26T07:00:00Z", [("0025", F.sets(3, rir: 5))])
        #expect(recovery([easy])[.chest]!.percent > recovery([hard])[.chest]!.percent)
    }

    @Test func missingEndUsesStart() {
        let w = Workout(startedAt: F.date("2026-09-25T09:00:00Z"), name: "W",
                        entries: [WorkoutEntry(exerciseId: "0025", sets: F.sets(3))])
        #expect(recovery([w])[.chest]!.percent == 79)
    }

    @Test func statusBands() {
        #expect(RecoveryStatus(percent: 100) == .fresh)
        #expect(RecoveryStatus(percent: 90) == .fresh)
        #expect(RecoveryStatus(percent: 89) == .recovering)
        #expect(RecoveryStatus(percent: 50) == .recovering)
        #expect(RecoveryStatus(percent: 49) == .fatigued)
    }

    @Test func freshestPrefersTrainedRotationMostRecoveredThenLongestAgo() {
        let workouts = [
            F.workout("2026-09-10T08:00:00Z", [("0198", F.sets(3))]),       // lats (+ biceps, forearms) 16 d ago
            F.workout("2026-09-20T08:00:00Z", [("0313", F.sets(3))]),       // biceps (+ forearms) 6 d ago
            F.workout("2026-09-25T20:00:00Z", [("0025", F.sets(3))]),       // chest yesterday: recovering
            F.workout("2026-08-01T08:00:00Z", [("0043", F.sets(3))]),       // legs > 28 d ago: out of rotation
        ]
        let all = RecoveryModel.compute(workouts: workouts, exercise: F.lookup, now: now)
        let fresh = RecoveryModel.freshest(all, limited: [], now: now)
        #expect(fresh == [.lats, .biceps, .forearms]) // chest/triceps/shoulders are still recovering
        #expect(RecoveryModel.freshest(all, limited: [], now: now, count: 2) == [.lats, .biceps])
        #expect(RecoveryModel.freshest(all, limited: [.biceps], now: now) == [.lats, .forearms])
        #expect(RecoveryModel.freshest(RecoveryModel.compute(workouts: [], exercise: F.lookup, now: now),
                                       limited: [], now: now).isEmpty)
    }
}
