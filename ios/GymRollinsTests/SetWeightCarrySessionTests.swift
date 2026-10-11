import Foundation
import GymCore
import Testing
@testable import GymRollins

/// Changing a set's weight on the exercise screen carries it to the later sets still to do.
@MainActor
@Suite struct SetWeightCarrySessionTests {
    struct NoNotifier: RestNotifier {
        func schedule(endsAt: Date) {}
        func cancel() {}
    }

    private func make(_ sets: [WorkoutSet]) -> WorkoutSession {
        let workout = Workout(startedAt: Date(timeIntervalSince1970: 1_000), name: "Home",
                              entries: [WorkoutEntry(exerciseId: "0541", sets: sets)])
        return WorkoutSession(
            workout: workout, clock: WorkoutClock(startedAt: workout.startedAt),
            restSeconds: 90, warmupRestSeconds: 60, notifier: NoNotifier(), now: { Date(timeIntervalSince1970: 1_100) },
            persist: { _, _ in }, previousBests: { _ in nil }, saveFinished: { _, _ in }, discard: {})
    }

    private func weights(_ s: WorkoutSession) -> [Double] { s.workout.entries[0].sets.map(\.weightKg) }

    @Test func aNewWeightCarriesToTheSetsStillToDo() {
        let s = make([WorkoutSet(weightKg: 20.4, reps: 12, done: true), WorkoutSet(weightKg: 20.4, reps: 12),
                      WorkoutSet(weightKg: 20.4, reps: 12), WorkoutSet(weightKg: 20.4, reps: 12)])
        let entry = s.workout.entries[0]
        let model = ExerciseScreenModel.workout(s, entryId: entry.id)
        model.updateSetCarryingWeight(entry.sets[1].id) { $0.with(weightKg: 24, reps: $0.reps) }
        #expect(weights(s) == [20.4, 24, 24, 24])
    }

    @Test func repsEditsAndHandChangedSetsDontCarry() {
        let s = make([WorkoutSet(weightKg: 20, reps: 10), WorkoutSet(weightKg: 22, reps: 10),
                      WorkoutSet(weightKg: 20, reps: 10)])
        let entry = s.workout.entries[0]
        let model = ExerciseScreenModel.workout(s, entryId: entry.id)
        model.updateSetCarryingWeight(entry.sets[0].id) { $0.with(weightKg: $0.weightKg, reps: 12) }
        #expect(weights(s) == [20, 22, 20])
        model.updateSetCarryingWeight(entry.sets[0].id) { $0.with(weightKg: 25, reps: $0.reps) }
        #expect(weights(s) == [25, 22, 20]) // set 2 was changed by hand: the carry stops there
        #expect(s.workout.entries[0].sets.map(\.reps) == [12, 10, 10])
    }
}
