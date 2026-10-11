import Foundation
import Testing
@testable import GymCore

@Suite struct WorkoutEditingTests {
    let warm = WorkoutSet(weightKg: 20.41, reps: 10, warmup: true)
    let s1 = WorkoutSet(weightKg: 63.5, reps: 8)
    let s2 = WorkoutSet(weightKg: 63.5, reps: 8)
    var bench: WorkoutEntry { WorkoutEntry(exerciseId: "0025", sets: [warm, s1, s2]) }
    var curl: WorkoutEntry { WorkoutEntry(exerciseId: "0070", sets: [WorkoutSet(weightKg: 24.9, reps: 10)]) }
    var workout: Workout { Workout(startedAt: Date(timeIntervalSince1970: 0), name: "Push", entries: [bench, curl]) }

    @Test func updatingSetReturnsNewWorkout() {
        let w = workout
        let e = w.entries[0]
        let updated = w.updatingSet(entryId: e.id, setId: e.sets[1].id) { $0.with(weightKg: 65, reps: 9) }
        #expect(updated.entries[0].sets[1].weightKg == 65)
        #expect(updated.entries[0].sets[1].reps == 9)
        #expect(w.entries[0].sets[1].weightKg == 63.5) // original untouched
    }

    @Test func appendingSetCopiesLastWorkingSetUndone() {
        let w = workout
        let e = w.entries[0]
        let done = w.updatingSet(entryId: e.id, setId: e.sets[2].id) { $0.completing(at: Date()) }
        let appended = done.appendingSet(entryId: e.id)
        let last = appended.entries[0].sets.last!
        #expect(appended.entries[0].sets.count == 4)
        #expect(last.weightKg == 63.5 && last.reps == 8 && !last.done && !last.warmup)
        #expect(last.id != e.sets[2].id)
    }

    @Test func insertingWarmupGoesBeforeFirstWorkingSet() {
        let w = workout
        let e = w.entries[0]
        let result = w.insertingWarmup(entryId: e.id, set: WorkoutSet(weightKg: 47.6, reps: 5, warmup: true))
        #expect(result.entries[0].sets.map(\.warmup) == [true, true, false, false])
        #expect(result.entries[0].sets[1].weightKg == 47.6)
    }

    @Test func removeSetEntryAndReplaceExercise() {
        let w = workout
        let e = w.entries[0]
        #expect(w.removingSet(entryId: e.id, setId: e.sets[0].id).entries[0].sets.count == 2)
        #expect(w.removingEntry(entryId: e.id).entries.map(\.exerciseId) == ["0070"])
        #expect(w.replacingExercise(entryId: e.id, exerciseId: "0314").entries[0].exerciseId == "0314")
        #expect(w.appendingEntries([WorkoutEntry(exerciseId: "0251")]).entries.count == 3)
        #expect(w.settingNote(entryId: e.id, note: "elbows in").entries[0].note == "elbows in")
    }

    @Test func undoneCountsAndFinish() {
        let w = workout
        let e = w.entries[0]
        let partly = w.updatingSet(entryId: e.id, setId: e.sets[1].id) { $0.completing(at: Date(timeIntervalSince1970: 60)) }
        #expect(partly.undoneSetCount == 3)
        #expect(partly.entriesWithUndoneSets.map(\.exerciseId) == ["0025", "0070"])
        let end = Date(timeIntervalSince1970: 3_000)
        let discarded = partly.finished(at: end, discardingUndone: true)
        #expect(discarded.endedAt == end)
        #expect(discarded.entries.map(\.exerciseId) == ["0025"])
        #expect(discarded.entries[0].sets.count == 1)
        let all = partly.markingAllDone(at: end).finished(at: end, discardingUndone: true)
        #expect(all.undoneSetCount == 0)
        #expect(all.entries.flatMap(\.sets).count == 4)
    }

    @Test func missingIdsAreNoOps() {
        let w = workout
        #expect(w.updatingSet(entryId: UUID(), setId: UUID()) { $0.with(weightKg: 1, reps: 1) } == w)
        #expect(w.removingEntry(entryId: UUID()) == w)
    }

    @Test func setCopiesChangeOnlyTheNamedFields() {
        let set = WorkoutSet(weightKg: 60, reps: 8, sec: 30, done: true, warmup: true, multiplier: 2,
                             completedAt: Date(timeIntervalSince1970: 5))
        let timed = set.with(sec: 20)
        #expect(timed.sec == 20 && timed.id == set.id && timed.weightKg == 60 && timed.done && timed.multiplier == 2)
        let cardio = set.with(minutes: 25, distanceM: 5_000)
        #expect(cardio.minutes == 25 && cardio.distanceM == 5_000 && cardio.sec == 30 && cardio.warmup)
        let single = set.with(multiplier: 1)
        #expect(single.multiplier == 1 && single.completedAt == set.completedAt && single.reps == 8)
    }
}
