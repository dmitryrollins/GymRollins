import Foundation
import GymCore
import Testing
@testable import GymRollins

@MainActor
@Suite struct WorkoutSessionTests {
    final class Spy {
        var persisted: [Workout] = []
        var finished: Workout?
        var finishedRecords: [PersonalRecord] = []
        var discarded = false
        var scheduled: [Date] = []
    }
    struct SpyNotifier: RestNotifier {
        let spy: Spy
        func schedule(endsAt: Date) { spy.scheduled.append(endsAt) }
        func cancel() {}
    }

    var t = Date(timeIntervalSince1970: 1_000)

    struct Failure: Error {}

    func make(_ spy: Spy, now: @escaping () -> Date, failSave: Bool = false,
              failDiscard: Bool = false) -> WorkoutSession {
        let workout = Workout(startedAt: Date(timeIntervalSince1970: 1_000), name: "Push", entries: [
            WorkoutEntry(exerciseId: "0025", sets: [
                WorkoutSet(weightKg: 20.41, reps: 10, warmup: true),
                WorkoutSet(weightKg: 61.2, reps: 8),
                WorkoutSet(weightKg: 61.2, reps: 8),
            ]),
            WorkoutEntry(exerciseId: "0070", sets: [WorkoutSet(weightKg: 24.9, reps: 10)]),
        ])
        return WorkoutSession(
            workout: workout, clock: WorkoutClock(startedAt: workout.startedAt),
            restSeconds: 120, warmupRestSeconds: 60, notifier: SpyNotifier(spy: spy), now: now,
            persist: { w, _ in spy.persisted.append(w) },
            previousBests: { _ in ExerciseBests(e1RMKg: 70, repsAtWeight: [:], volumeKg: 100) },
            saveFinished: { workout, records in
                if failSave { throw Failure() }
                spy.finished = workout
                spy.finishedRecords = records
            },
            discard: { if failDiscard { throw Failure() }; spy.discarded = true })
    }

    @Test func logSetMarksNextUndoneAndStartsRest() throws {
        let spy = Spy()
        var now = Date(timeIntervalSince1970: 1_100)
        let s = make(spy, now: { now })
        s.logNextSet(entryId: s.workout.entries[0].id, weightKg: 20.41, reps: 10)
        #expect(s.workout.entries[0].sets[0].done)
        #expect(s.rest?.duration == 60)                          // warm-up rest
        now = Date(timeIntervalSince1970: 1_200)
        s.logNextSet(entryId: s.workout.entries[0].id, weightKg: 63.5, reps: 8) // edited values are applied
        #expect(s.workout.entries[0].sets[1].weightKg == 63.5)
        #expect(s.rest?.duration == 120)
        #expect(spy.scheduled.count == 2)
        #expect(spy.persisted.count == 2)
    }

    @Test func finishingAnEntryAdvancesCurrent() {
        let spy = Spy()
        let s = make(spy, now: { Date(timeIntervalSince1970: 1_100) })
        let first = s.workout.entries[0].id
        #expect(s.currentEntryId == first)
        s.logAllSets(entryId: first)
        #expect(s.workout.entries[0].sets.allSatisfy { $0.done })
        #expect(s.currentEntryId == s.workout.entries[1].id)
    }

    @Test func pauseResumeAffectsElapsed() {
        let spy = Spy()
        var now = Date(timeIntervalSince1970: 1_600)
        let s = make(spy, now: { now })
        s.togglePause()
        now = Date(timeIntervalSince1970: 1_900)
        s.togglePause()
        #expect(s.elapsed(at: Date(timeIntervalSince1970: 2_000)) == 700)
    }

    @Test func finishDiscardingUndoneSavesAndSummarizes() throws {
        let spy = Spy()
        let s = make(spy, now: { Date(timeIntervalSince1970: 4_000) })
        s.logAllSets(entryId: s.workout.entries[0].id) // bench done; curl undone
        let summary = try s.finish(discardingUndone: true)
        let saved = try #require(spy.finished)
        #expect(saved.entries.map(\.exerciseId) == ["0025"])
        #expect(saved.endedAt == Date(timeIntervalSince1970: 4_000))
        #expect(summary.workingSets == 2)
        #expect(summary.records.contains { $0.kind == .volume })
        #expect(spy.finishedRecords == summary.records) // saveFinished receives the same records as the summary
    }

    /// Finishing while paused must count the still-open pause interval, not just `pausedSeconds` at
    /// the moment `finish` was called (the plan's `finish` resumes the clock first).
    @Test func finishWhilePausedCountsPauseTime() throws {
        let spy = Spy()
        var now = Date(timeIntervalSince1970: 1_600)
        let s = make(spy, now: { now })
        s.togglePause() // pause at 1_600
        now = Date(timeIntervalSince1970: 1_900) // 300s paused so far, still paused
        let summary = try s.finish(discardingUndone: false)
        let saved = try #require(spy.finished)
        // duration = (endedAt - startedAt) - pausedSeconds = (1_900 - 1_000) - 300 = 600
        #expect(saved.pausedSeconds == 300)
        #expect(saved.endedAt == Date(timeIntervalSince1970: 1_900))
        #expect(summary.durationSeconds == 600)
    }

    @Test func editingOperationsPersist() {
        let spy = Spy()
        let s = make(spy, now: { Date(timeIntervalSince1970: 1_100) })
        let bench = s.workout.entries[0].id
        s.addSet(entryId: bench)
        s.addWarmup(entryId: bench, barKg: 20.41)
        s.swap(entryId: bench, to: "0314", multiplier: 1, workingWeightKg: nil)
        s.setNote(entryId: bench, note: "slow eccentric")
        s.addExercises(["0251"], makeEntry: { WorkoutEntry(exerciseId: $0, sets: [WorkoutSet(weightKg: 0, reps: 10)]) })
        s.removeEntry(s.workout.entries[1].id)
        #expect(s.workout.entries.map(\.exerciseId) == ["0314", "0251"])
        #expect(s.workout.entries[0].sets.count == 5)
        #expect(s.workout.entries[0].note == "slow eccentric")
        #expect(spy.persisted.count == 6)
    }

    @Test func discardCallsDiscard() {
        let spy = Spy()
        let s = make(spy, now: { .now })
        #expect(s.discardWorkout())
        #expect(spy.discarded)
    }

    @Test func restDisabledSkipsRestTimer() {
        let spy = Spy()
        let s = make(spy, now: { Date(timeIntervalSince1970: 1_100) })
        s.restEnabled = false
        s.logNextSet(entryId: s.workout.entries[0].id, weightKg: 20.41, reps: 10)
        #expect(s.workout.entries[0].sets[0].done)
        #expect(s.rest == nil)
        #expect(spy.scheduled.isEmpty)
    }

    /// After exercise A completes the session advances its "in progress" highlight to B, but a
    /// LoggingView still showing A must keep logging A's sets.
    @Test func loggingTargetsTheGivenEntryNotTheAdvancedCurrent() {
        let spy = Spy()
        let s = make(spy, now: { Date(timeIntervalSince1970: 1_100) })
        let a = s.workout.entries[0].id, b = s.workout.entries[1].id
        s.logAllSets(entryId: a)
        #expect(s.currentEntryId == b)
        s.addSet(entryId: a)
        s.logNextSet(entryId: a, weightKg: 62, reps: 6)
        let added = s.workout.entries[0].sets[3]
        #expect(added.done && added.weightKg == 62 && added.reps == 6)
        #expect(!s.workout.entries[1].sets[0].done)
        #expect(s.workout.entries[1].sets[0].weightKg == 24.9)
        s.addSet(entryId: a)
        s.logAllSets(entryId: a)
        #expect(s.workout.entries[0].sets.allSatisfy { $0.done })
        #expect(!s.workout.entries[1].sets[0].done)
    }

    /// Barbell -> dumbbell swap doubles volume per logged weight (a pair); swapping back undoes it.
    @Test func swapReconcilesMultiplierAndWeights() {
        let spy = Spy()
        let s = make(spy, now: { Date(timeIntervalSince1970: 1_100) })
        let bench = s.workout.entries[0].id
        s.logNextSet(entryId: bench, weightKg: 20.41, reps: 10) // warm-up done
        s.swap(entryId: bench, to: "0289", multiplier: 2, workingWeightKg: 22)
        let swapped = s.workout.entries[0]
        #expect(swapped.exerciseId == "0289")
        #expect(swapped.sets.allSatisfy { $0.multiplier == 2 })
        #expect(swapped.sets[0].weightKg == 20.41)                       // done set keeps its load
        #expect(swapped.sets[1...].allSatisfy { $0.weightKg == 22 })    // undone working sets follow history
        s.swap(entryId: bench, to: "0025", multiplier: 1, workingWeightKg: nil)
        let back = s.workout.entries[0]
        #expect(back.sets.allSatisfy { $0.multiplier == 1 })
        #expect(back.sets[1...].allSatisfy { $0.weightKg == 22 })       // no history: keep
    }

    /// A 20 s hold logged against a 30 s target stores 20 s.
    @Test func timedSetLogsActualSeconds() {
        let spy = Spy()
        let s = make(spy, now: { Date(timeIntervalSince1970: 1_100) })
        s.addExercises(["plank"]) { WorkoutEntry(exerciseId: $0, sets: [WorkoutSet(weightKg: 0, reps: 1, sec: 30)]) }
        let plank = s.workout.entries[2].id
        s.logNextSet(entryId: plank, weightKg: 0, reps: 1, sec: 20)
        #expect(s.workout.entries[2].sets[0].sec == 20)
        #expect(s.workout.entries[2].sets[0].done)
    }

    /// A rest that ran out while the logging screen was closed is cleared centrally, so re-entering
    /// shows "Log Set" instead of a stuck 0:00 bar; the completion is counted once for the haptic.
    @Test func expiredRestIsClearedOnRead() {
        let spy = Spy()
        var now = Date(timeIntervalSince1970: 1_100)
        let s = make(spy, now: { now })
        s.logNextSet(entryId: s.workout.entries[0].id, weightKg: 20.41, reps: 10) // 60 s warm-up rest
        #expect(s.activeRest(at: Date(timeIntervalSince1970: 1_130))?.duration == 60)
        #expect(s.restCompletions == 0)
        now = Date(timeIntervalSince1970: 1_161)
        #expect(s.activeRest(at: now) == nil)
        #expect(s.rest == nil)
        #expect(s.restCompletions == 1)
        #expect(s.activeRest(at: now) == nil)
        #expect(s.restCompletions == 1)
        s.logNextSet(entryId: s.workout.entries[0].id, weightKg: 61.2, reps: 8)
        s.skipRest()
        #expect(s.restCompletions == 1) // skipping is not a completion
    }

    /// A failed delete must be reported so the flow stays open instead of pretending success.
    @Test func discardFailureReturnsFalseAndReports() {
        let spy = Spy()
        let s = make(spy, now: { .now }, failDiscard: true)
        #expect(!s.discardWorkout())
        #expect(!spy.discarded)
        #expect(s.lastError != nil)
    }

    /// Finishing surfaces save failures and leaves the workout unfinished, so the user can retry.
    @Test func finishFailureReportsAndAllowsRetry() throws {
        let spy = Spy()
        var failing = true
        let workout = Workout(startedAt: Date(timeIntervalSince1970: 1_000), name: "Push", entries: [
            WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: 60, reps: 8)])])
        let s = WorkoutSession(
            workout: workout, clock: WorkoutClock(startedAt: workout.startedAt),
            restSeconds: 120, warmupRestSeconds: 60, notifier: SpyNotifier(spy: spy),
            now: { Date(timeIntervalSince1970: 2_000) },
            persist: { w, _ in spy.persisted.append(w) }, previousBests: { _ in nil },
            saveFinished: { workout, _ in if failing { throw Failure() }; spy.finished = workout },
            discard: {})
        s.logAllSets(entryId: workout.entries[0].id)
        #expect(throws: Failure.self) { try s.finish(discardingUndone: false) }
        #expect(s.lastError != nil)
        #expect(s.workout.endedAt == nil)
        failing = false
        _ = try s.finish(discardingUndone: false)
        #expect(spy.finished != nil)
        #expect(s.lastError == nil)
    }
}

extension WorkoutSessionTests {
    /// The exercise screen's Remove Set checks the set as it is now, not the snapshot its menu was built from.
    @Test func removeSetIgnoresASetLoggedMeanwhile() {
        let spy = Spy()
        let session = make(spy, now: { Date(timeIntervalSince1970: 1_100) })
        let entry = session.workout.entries[0]
        let stale = entry.sets[0]
        session.logNextSet(entryId: entry.id, weightKg: stale.weightKg, reps: stale.reps) // e.g. from the watch
        let model = ExerciseScreenModel.workout(session, entryId: entry.id)
        #expect(!model.canRemoveSet(stale))
        model.removeSet(stale)
        #expect(session.entry(entry.id)?.sets.count == 3, "the logged set stays")
        model.removeSet(entry.sets[2])
        #expect(session.entry(entry.id)?.sets.count == 2)
    }
}
