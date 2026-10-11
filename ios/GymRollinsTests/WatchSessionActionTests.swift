import Foundation
import GymCore
import Testing
@testable import GymRollins

/// Apple Watch actions (plan 17) go through the same `WorkoutSession.perform` as the Live Activity buttons.
@MainActor
@Suite struct WatchSessionActionTests {
    final class Clock { var now = Date(timeIntervalSince1970: 1_000) }

    static let bench = Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell",
                                target: "pectorals")
    static let curl = Exercise(id: "0294", name: "dumbbell biceps curl", bodyPart: "upper arms", equipment: "dumbbell",
                               target: "biceps")
    static let plank = Exercise(id: "p", name: "plank", bodyPart: "waist", equipment: "body weight", target: "abs",
                                mode: .time)

    static func lookup(_ id: String) -> Exercise? { [bench, curl, plank].first { $0.id == id } }

    static func makeSession(_ clock: Clock, entries: [WorkoutEntry]? = nil) -> WorkoutSession {
        let workout = Workout(startedAt: clock.now, name: "Push", entries: entries ?? [
            WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: 61.2, reps: 8), WorkoutSet(weightKg: 61.2, reps: 8)]),
            WorkoutEntry(exerciseId: "p", sets: [WorkoutSet(weightKg: 0, reps: 0, sec: 45)]),
            WorkoutEntry(exerciseId: "0294", sets: [WorkoutSet(weightKg: 12, reps: 10)])
        ])
        return WorkoutSession(
            workout: workout, clock: WorkoutClock(startedAt: workout.startedAt), restSeconds: 120, warmupRestSeconds: 60,
            notifier: NoopRestNotifier(), now: { clock.now }, persist: { _, _ in }, previousBests: { _ in nil },
            saveFinished: { _, _ in }, discard: {})
    }

    let clock = Clock()

    @Test func logSetUsesTheWatchsWeightAndRepsAndStartsRest() {
        let s = Self.makeSession(clock)
        let entry = s.workout.entries[0]
        #expect(s.perform(.logSet(workoutId: s.workout.id, entryId: entry.id, setId: entry.sets[0].id, weightKg: 65,
                                  reps: 6), exercise: Self.lookup))
        let set = s.workout.entries[0].sets[0]
        #expect(set.done && set.weightKg == 65 && set.reps == 6)
        #expect(s.rest != nil)
    }

    @Test func logSetFollowsTheLiveActivityGuards() {
        let s = Self.makeSession(clock)
        let bench = s.workout.entries[0], plank = s.workout.entries[1]
        // Not the next set.
        #expect(!s.perform(.logSet(workoutId: s.workout.id, entryId: bench.id, setId: bench.sets[1].id, weightKg: 60,
                                   reps: 8), exercise: Self.lookup))
        // Another workout.
        #expect(!s.perform(.logSet(workoutId: UUID(), entryId: bench.id, setId: bench.sets[0].id, weightKg: 60, reps: 8),
                           exercise: Self.lookup))
        // A timed exercise is logged on the phone.
        #expect(!s.perform(.logSet(workoutId: s.workout.id, entryId: plank.id, setId: plank.sets[0].id, weightKg: 0,
                                   reps: 0), exercise: Self.lookup))
        #expect(s.workout.entries.allSatisfy { $0.sets.allSatisfy { !$0.done } })
    }

    @Test func aDuplicateLogSetIsIgnored() {
        let s = Self.makeSession(clock)
        let entry = s.workout.entries[0]
        let action = WorkoutActivityAction.logSet(workoutId: s.workout.id, entryId: entry.id, setId: entry.sets[0].id,
                                                  weightKg: 60, reps: 8)
        #expect(s.perform(action, exercise: Self.lookup))
        let before = s.workout
        #expect(!s.perform(action, exercise: Self.lookup))
        #expect(s.workout == before)
    }

    @Test func showExerciseMovesAmongExercisesWithSetsLeft() {
        let s = Self.makeSession(clock)
        let ids = s.workout.entries.map(\.id)
        #expect(s.currentEntryId == ids[0])
        #expect(s.perform(.showExercise(workoutId: s.workout.id, fromEntryId: ids[0], step: .next), exercise: Self.lookup))
        #expect(s.currentEntryId == ids[1])
        #expect(s.perform(.showExercise(workoutId: s.workout.id, fromEntryId: ids[1], step: .next), exercise: Self.lookup))
        #expect(s.currentEntryId == ids[2])
        #expect(!s.perform(.showExercise(workoutId: s.workout.id, fromEntryId: ids[2], step: .next), exercise: Self.lookup))
        #expect(s.perform(.showExercise(workoutId: s.workout.id, fromEntryId: ids[2], step: .previous),
                          exercise: Self.lookup))
        #expect(s.currentEntryId == ids[1])
    }

    @Test func showExerciseSkipsFinishedExercises() {
        let s = Self.makeSession(clock)
        let ids = s.workout.entries.map(\.id)
        s.logAllSets(entryId: ids[1]) // plank done
        #expect(s.perform(.showExercise(workoutId: s.workout.id, fromEntryId: ids[0], step: .next), exercise: Self.lookup))
        #expect(s.currentEntryId == ids[2])
    }

    @Test func aStaleShowExerciseIsIgnored() {
        let s = Self.makeSession(clock)
        let ids = s.workout.entries.map(\.id)
        // The watch still showed the first exercise, but the phone moved on.
        s.select(ids[2])
        #expect(!s.perform(.showExercise(workoutId: s.workout.id, fromEntryId: ids[0], step: .next), exercise: Self.lookup))
        #expect(s.currentEntryId == ids[2])
    }

    @Test func neighboursForTheWatchsButtons() {
        let s = Self.makeSession(clock)
        let ids = s.workout.entries.map(\.id)
        #expect(WorkoutActivityContent.neighbor(of: ids[0], step: .previous, in: s.workout) == nil)
        #expect(WorkoutActivityContent.neighbor(of: ids[0], step: .next, in: s.workout)?.id == ids[1])
        #expect(WorkoutActivityContent.neighbor(of: ids[2], step: .previous, in: s.workout)?.id == ids[1])
        #expect(WorkoutActivityContent.neighbor(of: UUID(), step: .next, in: s.workout) == nil)
    }
}
