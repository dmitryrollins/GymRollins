import Foundation
import Testing
@testable import GymCore

struct HardSetsTests {
    @Test func warmupsUndoneAndEmptySetsDontCount() {
        #expect(HardSets.isHard(WorkoutSet(weightKg: 60, reps: 8, done: true)))
        #expect(!HardSets.isHard(WorkoutSet(weightKg: 60, reps: 8, done: true, warmup: true)))
        #expect(!HardSets.isHard(WorkoutSet(weightKg: 60, reps: 8, done: false)))
        #expect(!HardSets.isHard(WorkoutSet(weightKg: 60, reps: 0, done: true)))
    }

    @Test func bodyweightAndTimedSetsCount() {
        #expect(HardSets.isHard(WorkoutSet(weightKg: 0, reps: 12, done: true)))
        #expect(HardSets.isHard(WorkoutSet(weightKg: 0, reps: 1, sec: 45, done: true)))
        #expect(HardSets.isHard(WorkoutSet(weightKg: 0, reps: 0, sec: 45, done: true)))
        #expect(HardSets.isHard(WorkoutSet(weightKg: 0, reps: 0, minutes: 2, done: true)))
    }

    @Test func effortFromRirOrRpe() {
        #expect(HardSets.effort(WorkoutSet(weightKg: 1, reps: 1)) == 1)
        #expect(HardSets.effort(WorkoutSet(weightKg: 1, reps: 1, rir: 0)) == 1)
        #expect(HardSets.effort(WorkoutSet(weightKg: 1, reps: 1, rir: 1)) == 1)
        #expect(HardSets.effort(WorkoutSet(weightKg: 1, reps: 1, rir: 2)) == 0.9)
        #expect(HardSets.effort(WorkoutSet(weightKg: 1, reps: 1, rir: 3)) == 0.75)
        #expect(HardSets.effort(WorkoutSet(weightKg: 1, reps: 1, rir: 4)) == 0.6)
        #expect(HardSets.effort(WorkoutSet(weightKg: 1, reps: 1, rir: 6)) == 0.5)
        #expect(HardSets.effort(WorkoutSet(weightKg: 1, reps: 1, rpe: 8)) == 0.9) // RIR 2
        #expect(HardSets.effort(WorkoutSet(weightKg: 1, reps: 1, rpe: 10)) == 1)
        #expect(HardSets.effort(WorkoutSet(weightKg: 1, reps: 1, rir: 2, rpe: 10)) == 0.9) // RIR wins
        #expect(HardSets.effort(WorkoutSet(weightKg: 1, reps: 1, rir: 2.5)) == 0.9) // rounds down to the harder band
    }

    @Test func loadsPerGroupForOneWorkout() {
        let w = InsightsFixture.workout("2026-09-25T18:00:00Z", [
            ("0025", InsightsFixture.sets(1, warmup: true) + InsightsFixture.sets(3)),
            ("0025", InsightsFixture.sets(1, rir: 3)),
        ])
        let loads = MuscleLoads.of(w, exercise: InsightsFixture.lookup)
        #expect(loads[.chest] == MuscleLoads.Load(sets: 4, load: 3.75))
        #expect(loads[.triceps] == MuscleLoads.Load(sets: 2, load: 1.875))
        #expect(loads[.shoulders] == MuscleLoads.Load(sets: 2, load: 1.875))
        #expect(loads[.biceps] == nil)
    }

    @Test func unknownExerciseAndCardioAreSkipped() {
        let w = InsightsFixture.workout("2026-09-25T18:00:00Z", [
            ("nope", InsightsFixture.sets(3)), ("run", InsightsFixture.sets(1, reps: 1, sec: 1_800)),
        ])
        #expect(MuscleLoads.of(w, exercise: InsightsFixture.lookup).isEmpty)
    }
}
