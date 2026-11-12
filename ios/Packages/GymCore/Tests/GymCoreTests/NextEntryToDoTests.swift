import Foundation
import Testing
@testable import GymCore

@Suite struct NextEntryToDoTests {
    private func entry(done: Bool) -> WorkoutEntry {
        WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: 20, reps: 10, done: done)])
    }

    private func workout(_ entries: [WorkoutEntry]) -> Workout {
        Workout(startedAt: Date(timeIntervalSince1970: 0), name: "Push", entries: entries)
    }

    @Test func theNextExerciseAfterThisOne() {
        let e = [entry(done: true), entry(done: false), entry(done: false)]
        #expect(workout(e).nextEntryToDo(after: e[0].id) == e[1].id)
    }

    @Test func anExerciseAlreadyDoneIsSkipped() {
        let e = [entry(done: true), entry(done: true), entry(done: false)]
        #expect(workout(e).nextEntryToDo(after: e[0].id) == e[2].id)
    }

    @Test func wrapsRoundToAnEarlierExercise() {
        let e = [entry(done: false), entry(done: true), entry(done: true)]
        #expect(workout(e).nextEntryToDo(after: e[2].id) == e[0].id)
    }

    @Test func nilWhenAllAreDone() {
        let e = [entry(done: true), entry(done: true)]
        #expect(workout(e).nextEntryToDo(after: e[0].id) == nil)
    }

    @Test func nilForAnUnknownId() {
        let e = [entry(done: false)]
        #expect(workout(e).nextEntryToDo(after: UUID()) == nil)
    }
}
