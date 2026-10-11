import Foundation
import GymCore
import Testing
@testable import GymRollins

/// The lock-screen buttons act on the same `WorkoutSession` the logging screen uses.
@MainActor
@Suite struct WorkoutActivityActionTests {
    final class Spy {
        var persisted: [Workout] = []
        var scheduled: [Date] = []
        var cancelled = 0
    }
    struct SpyNotifier: RestNotifier {
        let spy: Spy
        func schedule(endsAt: Date) { spy.scheduled.append(endsAt) }
        func cancel() { spy.cancelled += 1 }
    }
    final class Clock { var now = Date(timeIntervalSince1970: 1_000) }

    let bench = Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell",
                         target: "pectorals")
    let plank = Exercise(id: "p", name: "plank", bodyPart: "waist", equipment: "body weight", target: "abs",
                         mode: .time)

    private func lookup(_ id: String) -> Exercise? { [bench, plank].first { $0.id == id } }

    private func make(_ spy: Spy, _ clock: Clock) -> WorkoutSession {
        let workout = Workout(startedAt: clock.now, name: "Push", entries: [
            WorkoutEntry(exerciseId: "0025", sets: [
                WorkoutSet(weightKg: 61.2, reps: 8),
                WorkoutSet(weightKg: 61.2, reps: 8),
                WorkoutSet(weightKg: 61.2, reps: 8)
            ]),
            WorkoutEntry(exerciseId: "p", sets: [WorkoutSet(weightKg: 0, reps: 0, sec: 45)])
        ])
        return WorkoutSession(
            workout: workout, clock: WorkoutClock(startedAt: workout.startedAt),
            restSeconds: 120, warmupRestSeconds: 60, notifier: SpyNotifier(spy: spy), now: { clock.now },
            persist: { w, _ in spy.persisted.append(w) },
            previousBests: { _ in nil }, saveFinished: { _, _ in }, discard: {})
    }

    private func logNext(_ s: WorkoutSession, entry: Int = 0) -> WorkoutActivityAction {
        let e = s.workout.entries[entry]
        let set = e.sets.first { !$0.done }!
        return .logPlannedSet(workoutId: s.workout.id, entryId: e.id, setId: set.id)
    }

    // MARK: Log set

    @Test func logsThePlannedSetWithItsStoredValuesAndStartsRest() {
        let spy = Spy(), clock = Clock()
        let s = make(spy, clock)
        s.update(entryId: s.workout.entries[0].id, setId: s.workout.entries[0].sets[0].id) {
            $0.with(weightKg: 63.5, reps: 6) // edited in the app before locking the phone
        }
        clock.now = Date(timeIntervalSince1970: 1_100)
        #expect(s.perform(logNext(s), exercise: lookup))
        let set = s.workout.entries[0].sets[0]
        #expect(set.done && set.weightKg == 63.5 && set.reps == 6)
        #expect(set.completedAt == clock.now)
        #expect(!s.workout.entries[0].sets[1].done)
        #expect(s.rest == RestTimer(startedAt: clock.now, duration: 120))
        #expect(spy.scheduled == [clock.now.addingTimeInterval(120)])
        #expect(spy.persisted.last == s.workout)
    }

    @Test func aStaleSetIdIsIgnored() {
        let spy = Spy(), clock = Clock()
        let s = make(spy, clock)
        let stale = logNext(s)
        #expect(s.perform(stale, exercise: lookup))
        let before = s.workout
        #expect(!s.perform(stale, exercise: lookup)) // double tap: that set is already logged
        #expect(s.workout == before)
    }

    @Test func anotherWorkoutsActionIsIgnored() {
        let spy = Spy(), clock = Clock()
        let s = make(spy, clock)
        let e = s.workout.entries[0]
        #expect(!s.perform(.logPlannedSet(workoutId: UUID(), entryId: e.id, setId: e.sets[0].id), exercise: lookup))
        #expect(!s.workout.entries[0].sets[0].done)
        #expect(spy.persisted.isEmpty)
    }

    @Test func timedExercisesAreNotLoggedFromTheLockScreen() {
        let spy = Spy(), clock = Clock()
        let s = make(spy, clock)
        #expect(!s.perform(logNext(s, entry: 1), exercise: lookup))
        #expect(!s.workout.entries[1].sets[0].done)
    }

    @Test func nothingHappensAfterTheWorkoutIsFinishedOrAbandoned() throws {
        let spy = Spy(), clock = Clock()
        let s = make(spy, clock)
        let action = logNext(s)
        s.abandon()
        #expect(!s.perform(action, exercise: lookup))

        let finished = make(Spy(), Clock())
        let finishedAction = logNext(finished)
        _ = try finished.finish(discardingUndone: true)
        #expect(!finished.perform(finishedAction, exercise: lookup))
    }

    @Test func loggingTheLastSetOfAnExerciseAdvancesWithoutRest() {
        let spy = Spy(), clock = Clock()
        let s = make(spy, clock)
        for _ in 0..<2 { _ = s.perform(logNext(s), exercise: lookup) }
        s.skipRest()
        #expect(s.perform(logNext(s), exercise: lookup))
        #expect(s.rest == nil)
        #expect(s.currentEntryId == s.workout.entries[1].id)
    }

    @Test func loggingFromTheLockScreenSelectsThatExercise() {
        // After a cold start the current entry is the first with undone sets, while the activity may show a later
        // one; the tapped exercise must stay the one the activity follows.
        let spy = Spy(), clock = Clock()
        let workout = Workout(startedAt: clock.now, name: "W", entries: [
            WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: 60, reps: 8)]),
            WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: 40, reps: 10), WorkoutSet(weightKg: 40, reps: 10)])
        ])
        let s = WorkoutSession(
            workout: workout, clock: WorkoutClock(startedAt: clock.now), restSeconds: 120, warmupRestSeconds: 60,
            notifier: SpyNotifier(spy: spy), now: { clock.now }, persist: { _, _ in }, previousBests: { _ in nil },
            saveFinished: { _, _ in }, discard: {})
        #expect(s.currentEntryId == workout.entries[0].id)
        #expect(s.perform(logNext(s, entry: 1), exercise: lookup))
        #expect(s.currentEntryId == workout.entries[1].id)
    }

    @Test func restActionsKeepTheExerciseTheActivityShows() {
        let spy = Spy(), clock = Clock()
        let s = make(spy, clock)
        let bench = s.workout.entries[0], plankEntry = s.workout.entries[1]
        _ = s.perform(logNext(s), exercise: lookup)
        s.select(bench.id) // what a cold start restores: the first entry with undone sets
        #expect(s.perform(.extendRest(workoutId: s.workout.id, entryId: plankEntry.id, seconds: 30), exercise: lookup))
        #expect(s.currentEntryId == plankEntry.id)
        s.select(bench.id)
        #expect(s.perform(.skipRest(workoutId: s.workout.id, entryId: plankEntry.id), exercise: lookup))
        #expect(s.currentEntryId == plankEntry.id)
    }

    @Test func loggingTheLastSetDuringARestEndsThatRest() {
        let spy = Spy(), clock = Clock()
        let s = make(spy, clock)
        _ = s.perform(logNext(s), exercise: lookup)
        _ = s.perform(logNext(s), exercise: lookup)
        #expect(s.rest != nil)
        let cancelledBefore = spy.cancelled
        #expect(s.perform(logNext(s), exercise: lookup)) // last bench set, still resting
        #expect(s.rest == nil)
        #expect(spy.cancelled == cancelledBefore + 1)
    }

    // MARK: Rest

    @Test func extendAddsToTheRunningRestAndReschedules() {
        let spy = Spy(), clock = Clock()
        let s = make(spy, clock)
        _ = s.perform(logNext(s), exercise: lookup)
        clock.now = clock.now.addingTimeInterval(100)
        #expect(s.perform(.extendRest(workoutId: s.workout.id, entryId: nil, seconds: 30), exercise: lookup))
        #expect(s.rest?.duration == 150)
        #expect(spy.scheduled.last == Date(timeIntervalSince1970: 1_150))
    }

    @Test func extendDoesNothingOnceRestIsOver() {
        let spy = Spy(), clock = Clock()
        let s = make(spy, clock)
        _ = s.perform(logNext(s), exercise: lookup)
        clock.now = clock.now.addingTimeInterval(200)
        #expect(!s.perform(.extendRest(workoutId: s.workout.id, entryId: nil, seconds: 30), exercise: lookup))
        #expect(s.rest == nil)
        #expect(spy.scheduled.count == 1)
    }

    @Test func skipEndsTheRest() {
        let spy = Spy(), clock = Clock()
        let s = make(spy, clock)
        _ = s.perform(logNext(s), exercise: lookup)
        #expect(s.perform(.skipRest(workoutId: s.workout.id, entryId: nil), exercise: lookup))
        #expect(s.rest == nil)
        #expect(spy.cancelled == 1)
        #expect(!s.perform(.skipRest(workoutId: s.workout.id, entryId: nil), exercise: lookup)) // nothing left to skip
        #expect(!s.perform(.skipRest(workoutId: UUID(), entryId: nil), exercise: lookup))
    }
}
