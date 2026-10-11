import Foundation
import GymCore
import Testing
@testable import GymRollins

@Suite struct WorkoutActivityContentTests {
    let t0 = Date(timeIntervalSince1970: 10_000)
    let bench = Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell",
                         target: "pectorals")
    let plank = Exercise(id: "p", name: "plank", bodyPart: "waist", equipment: "body weight", target: "abs",
                         mode: .time)
    let run = Exercise(id: "r", name: "run", bodyPart: "cardio", equipment: "body weight", target: "heart")
    let pullup = Exercise(id: "pu", name: "pull-up", bodyPart: "back", equipment: "body weight", target: "lats")

    private var lb135: Double { UnitConverter.toKg(135, from: .lb) }

    private func lookup(_ id: String) -> Exercise? { [bench, plank, run, pullup].first { $0.id == id } }

    private func benchEntry(done: Int = 0) -> WorkoutEntry {
        let sets = [WorkoutSet(weightKg: 20.41, reps: 10, warmup: true), WorkoutSet(weightKg: 40.8, reps: 5, warmup: true)]
            + (0..<5).map { _ in WorkoutSet(weightKg: lb135, reps: 8) }
        return WorkoutEntry(exerciseId: "0025", sets: sets.enumerated().map { $0.offset < done ? $0.element.completing(at: t0) : $0.element })
    }

    private func state(_ workout: Workout, current: UUID? = nil, rest: RestTimer? = nil, now: Date? = nil,
                       unit: WeightUnit = .lb) -> WorkoutActivityAttributes.ContentState? {
        WorkoutActivityContent.state(workout: workout, currentEntryId: current, rest: rest, now: now ?? t0, unit: unit,
                                     exercise: lookup)
    }

    // MARK: Next planned set

    @Test func showsTheNextWorkingSetInPounds() throws {
        let entry = benchEntry(done: 4)
        let s = try #require(state(Workout(startedAt: t0, name: "Push", entries: [entry]), current: entry.id))
        #expect(s.exerciseName == "Barbell Bench Press")
        #expect(s.setLabel == "Set 3/5")
        #expect(s.setDetail == "135 lb × 8")
        #expect(s.entryId == entry.id)
        #expect(s.setId == entry.sets[4].id)
        #expect(s.canLogSet)
        #expect(!s.isComplete)
    }

    @Test func showsWarmupsWithTheirOwnCountAndKilograms() throws {
        let entry = benchEntry(done: 0)
        let s = try #require(state(Workout(startedAt: t0, name: "Push", entries: [entry]), unit: .kg))
        #expect(s.setLabel == "Warm-up 1/2")
        #expect(s.setDetail == "20.4 kg × 10")
    }

    @Test func bodyweightSetsShowRepsOnly() throws {
        let entry = WorkoutEntry(exerciseId: "pu", sets: [WorkoutSet(weightKg: 0, reps: 8)])
        let s = try #require(state(Workout(startedAt: t0, name: "Pull", entries: [entry])))
        #expect(s.setLabel == "Set 1/1")
        #expect(s.setDetail == "8 reps")
        #expect(s.canLogSet)
    }

    // MARK: Target entry

    @Test func followsTheCurrentEntryWhileItHasUndoneSets() throws {
        let first = benchEntry()
        let second = WorkoutEntry(exerciseId: "pu", sets: [WorkoutSet(weightKg: 0, reps: 8)])
        let s = try #require(state(Workout(startedAt: t0, name: "W", entries: [first, second]), current: second.id))
        #expect(s.entryId == second.id)
    }

    @Test func fallsBackToTheFirstEntryWithUndoneSets() throws {
        let done = benchEntry(done: 7)
        let next = WorkoutEntry(exerciseId: "pu", sets: [WorkoutSet(weightKg: 0, reps: 8)])
        let workout = Workout(startedAt: t0, name: "W", entries: [done, next])
        #expect(try #require(state(workout, current: done.id)).entryId == next.id)
        #expect(try #require(state(workout, current: nil)).entryId == next.id)
        #expect(try #require(state(workout, current: UUID())).entryId == next.id)
    }

    @Test func allSetsDoneShowsTheWorkoutWithoutLogSet() throws {
        let s = try #require(state(Workout(startedAt: t0, name: "Push", entries: [benchEntry(done: 7)])))
        #expect(s.isComplete)
        #expect(s.exerciseName == "Push")
        #expect(s.setLabel == "All sets done")
        #expect(s.setDetail.isEmpty)
        #expect(!s.canLogSet)
        #expect(s.entryId == nil && s.setId == nil)
    }

    @Test func emptyWorkoutAsksForAnExercise() throws {
        let s = try #require(state(Workout(startedAt: t0, name: "Workout")))
        #expect(s.isComplete)
        #expect(s.setLabel == "Add an exercise")
    }

    @Test func finishedWorkoutHasNoActivity() {
        let finished = Workout(startedAt: t0, endedAt: t0.addingTimeInterval(60), name: "Push", entries: [benchEntry()])
        #expect(state(finished) == nil)
    }

    // MARK: Reps-only rule

    @Test func timedExerciseShowsSecondsWithoutLogSet() throws {
        let entry = WorkoutEntry(exerciseId: "p", sets: [WorkoutSet(weightKg: 0, reps: 0, sec: 45),
                                                         WorkoutSet(weightKg: 0, reps: 0, sec: 45)])
        let s = try #require(state(Workout(startedAt: t0, name: "Core", entries: [entry])))
        #expect(s.setLabel == "Set 1/2")
        #expect(s.setDetail == "45 s")
        #expect(!s.canLogSet)
        #expect(s.setId == entry.sets[0].id)
    }

    @Test func cardioShowsMinutesAndDistanceWithoutLogSet() throws {
        let entry = WorkoutEntry(exerciseId: "r", sets: [WorkoutSet(weightKg: 0, reps: 0, minutes: 20,
                                                                    distanceM: 3.1 * 1_609.344)])
        let s = try #require(state(Workout(startedAt: t0, name: "Cardio", entries: [entry])))
        #expect(s.setDetail == "20 min · 3.1 mi")
        #expect(!s.canLogSet)
    }

    @Test func importedTimedSetsOnARepsExerciseFollowTheData() {
        // Fitbod's timed plank can map to a reps-mode library entry; its sets carry seconds, not reps.
        let entry = WorkoutEntry(exerciseId: "pu", sets: [WorkoutSet(weightKg: 0, reps: 0, sec: 30)])
        #expect(!WorkoutActivityContent.canLogPlannedSet(entry, exercise: pullup))
        #expect(WorkoutActivityContent.canLogPlannedSet(benchEntry(), exercise: bench))
        #expect(!WorkoutActivityContent.canLogPlannedSet(benchEntry(done: 7), exercise: bench))
    }

    @Test func unknownExerciseUsesItsIdAndTheSetShape() throws {
        let entry = WorkoutEntry(exerciseId: "custom-x", sets: [WorkoutSet(weightKg: 10, reps: 12)])
        let s = try #require(state(Workout(startedAt: t0, name: "W", entries: [entry]), unit: .kg))
        #expect(s.exerciseName == "Custom-X")
        #expect(s.setDetail == "10 kg × 12")
        #expect(s.canLogSet)
    }

    // MARK: Rest

    @Test func includesARunningRest() throws {
        let rest = RestTimer(startedAt: t0, duration: 90)
        let s = try #require(state(Workout(startedAt: t0, name: "W", entries: [benchEntry()]), rest: rest,
                                   now: t0.addingTimeInterval(30)))
        #expect(s.restStartedAt == t0)
        #expect(s.restEndsAt == t0.addingTimeInterval(90))
        #expect(s.restInterval == t0...t0.addingTimeInterval(90))
    }

    @Test func dropsAFinishedRest() throws {
        let rest = RestTimer(startedAt: t0, duration: 90)
        let s = try #require(state(Workout(startedAt: t0, name: "W", entries: [benchEntry()]), rest: rest,
                                   now: t0.addingTimeInterval(90)))
        #expect(s.restStartedAt == nil && s.restEndsAt == nil && s.restInterval == nil)
    }
}
