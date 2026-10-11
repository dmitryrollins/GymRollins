import Foundation
import Testing
@testable import GymCore

@Suite struct SetEffortTests {
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    @Test func withRirReturnsACopyAndKeepsEverythingElse() {
        let set = WorkoutSet(weightKg: 60, reps: 8, sec: 3, done: true, rpe: 8, multiplier: 2, completedAt: at(5))
        let rated = set.with(rir: 2)
        #expect(rated.rir == 2)
        #expect(set.rir == nil)
        #expect(rated.with(rir: nil) == set)
        #expect(rated.id == set.id && rated.rpe == 8 && rated.multiplier == 2 && rated.completedAt == at(5))
    }

    @Test func onlyDoneWorkingRepsSetsCanBeRated() {
        let done = WorkoutSet(weightKg: 60, reps: 8, done: true)
        #expect(SetEffort.canRate(done, mode: .reps))
        #expect(!SetEffort.canRate(WorkoutSet(weightKg: 60, reps: 8), mode: .reps))
        #expect(!SetEffort.canRate(WorkoutSet(weightKg: 20, reps: 10, done: true, warmup: true), mode: .reps))
        #expect(!SetEffort.canRate(done, mode: .time))
        #expect(!SetEffort.canRate(done, mode: .cardio))
    }

    @Test func choicesAreZeroToFourPlus() {
        #expect(SetEffort.choices == [0, 1, 2, 3, 4])
        #expect(SetEffort.choice(for: nil) == nil)
        #expect(SetEffort.choice(for: 0) == 0)
        #expect(SetEffort.choice(for: 2) == 2)
        #expect(SetEffort.choice(for: 4) == 4)
        #expect(SetEffort.choice(for: 6) == 4) // imported 5+ shows as "4+"
        #expect(SetEffort.choice(for: 2.5) == 2) // a fraction shows the harder chip
    }

    @Test func tappingStoresTappingTheSelectedChipClears() {
        #expect(SetEffort.toggled(nil, tapping: 2) == 2)
        #expect(SetEffort.toggled(2, tapping: 3) == 3)
        #expect(SetEffort.toggled(3, tapping: 3) == nil)
        #expect(SetEffort.toggled(nil, tapping: 4) == 4) // "4+" is stored as 4
        #expect(SetEffort.toggled(6, tapping: 4) == nil)
        #expect(SetEffort.toggled(nil, tapping: 9) == 4) // out of range clamps
        #expect(SetEffort.toggled(nil, tapping: -1) == 0)
    }

    /// Asked once per exercise: only after its last working set is logged, on that set.
    @Test func promptWaitsForTheLastWorkingSet() {
        let warmup = WorkoutSet(weightKg: 20, reps: 10, done: true, warmup: true, completedAt: at(30))
        let first = WorkoutSet(weightKg: 60, reps: 8, done: true, completedAt: at(10))
        let second = WorkoutSet(weightKg: 60, reps: 8, done: true, completedAt: at(20))
        let undone = WorkoutSet(weightKg: 60, reps: 8)
        #expect(SetEffort.promptSetId(in: [warmup, first, second, undone], mode: .reps) == nil, "a set is still to do")
        #expect(SetEffort.promptSetId(in: [warmup, first, second], mode: .reps) == second.id)
        #expect(SetEffort.promptSetId(in: [warmup, undone], mode: .reps) == nil)
        #expect(SetEffort.promptSetId(in: [warmup], mode: .reps) == nil, "warm-ups only")
        #expect(SetEffort.promptSetId(in: [first, second], mode: .time) == nil)
    }

    @Test func logAllTiesGoToTheLastSet() {
        let a = WorkoutSet(weightKg: 60, reps: 8, done: true, completedAt: at(10))
        let b = WorkoutSet(weightKg: 60, reps: 8, done: true, completedAt: at(10))
        let imported = WorkoutSet(weightKg: 60, reps: 8, done: true)
        #expect(SetEffort.promptSetId(in: [a, b], mode: .reps) == b.id)
        #expect(SetEffort.promptSetId(in: [imported, a], mode: .reps) == a.id)
    }

    /// A rating made the way the live workout makes it (updatingSet + with(rir:)) lowers that set's recovery load.
    @Test func aLoggedRirFlowsIntoTheRecoveryLoad() throws {
        let workout = InsightsFixture.workout("2026-09-25T18:00:00Z", [("0025", InsightsFixture.sets(2))])
        let entry = try #require(workout.entries.first)
        let rated = workout.updatingSet(entryId: entry.id, setId: entry.sets[0].id) {
            $0.with(rir: SetEffort.toggled($0.rir, tapping: 3))
        }
        #expect(MuscleLoads.of(workout, exercise: InsightsFixture.lookup)[.chest]?.load == 2)
        #expect(MuscleLoads.of(rated, exercise: InsightsFixture.lookup)[.chest]?.load == 1.75)
    }
}
