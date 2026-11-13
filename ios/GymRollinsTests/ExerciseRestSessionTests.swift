import Foundation
import GymCore
import Testing
@testable import GymRollins

/// A rest set on one exercise stays with that exercise: the workout's other exercises keep their own rest or the
/// workout default, and warm-ups keep the workout's warm-up rest.
@MainActor
@Suite struct ExerciseRestSessionTests {
    struct NoNotifier: RestNotifier {
        func schedule(endsAt: Date) {}
        func cancel() {}
    }

    /// The per-exercise rests the session reads and writes (the app's `ExerciseRestStore`, without the suggestion).
    final class Rests {
        var custom: [String: TimeInterval]
        var saved: [(id: String, seconds: TimeInterval, defaultSec: TimeInterval)] = []
        init(_ custom: [String: TimeInterval]) { self.custom = custom }
    }

    private func make(_ rests: Rests) -> WorkoutSession {
        let working = { WorkoutSet(weightKg: 60, reps: 8) }
        let workout = Workout(startedAt: Date(timeIntervalSince1970: 1_000), name: "Push", entries: [
            WorkoutEntry(exerciseId: "A", sets: [WorkoutSet(weightKg: 20, reps: 10, warmup: true), working(), working()]),
            WorkoutEntry(exerciseId: "B", sets: [working(), working(), working()]),
        ])
        return WorkoutSession(
            workout: workout, clock: WorkoutClock(startedAt: workout.startedAt),
            restSeconds: 120, warmupRestSeconds: 60, notifier: NoNotifier(), now: { Date(timeIntervalSince1970: 1_100) },
            persist: { _, _ in }, previousBests: { _ in nil }, saveFinished: { _, _ in }, discard: {},
            workingRest: { rests.custom[$0] ?? $1 },
            saveWorkingRest: { id, seconds, defaultSec in
                rests.saved.append((id, seconds, defaultSec))
                rests.custom[id] = seconds
            })
    }

    @Test func eachExerciseRestsItsOwnTimeAfterAWorkingSet() {
        let s = make(Rests(["A": 300]))
        let a = s.workout.entries[0], b = s.workout.entries[1]
        s.logNextSet(entryId: a.id, weightKg: 20, reps: 10)
        #expect(s.rest?.duration == 60, "warm-ups keep the workout's warm-up rest")
        s.logNextSet(entryId: a.id, weightKg: 60, reps: 8)
        #expect(s.rest?.duration == 300)
        s.logNextSet(entryId: b.id, weightKg: 60, reps: 8)
        #expect(s.rest?.duration == 120, "B has none of its own: the workout default")
        #expect(s.workingRestSeconds(entryId: a.id) == 300)
        #expect(s.workingRestSeconds(entryId: b.id) == 120)
    }

    @Test func aSwappedEntryRestsTheNewExercisesTime() {
        let s = make(Rests(["A": 300, "C": 45]))
        let a = s.workout.entries[0]
        s.swap(entryId: a.id, to: "C", multiplier: 1, target: .keep)
        #expect(s.workingRestSeconds(entryId: a.id) == 45)
        s.logNextSet(entryId: a.id, weightKg: 20, reps: 10)
        s.logNextSet(entryId: a.id, weightKg: 60, reps: 8)
        #expect(s.rest?.duration == 45)
    }

    @Test func changingOneExercisesRestLeavesTheOthersAlone() {
        let rests = Rests([:])
        let s = make(rests)
        let a = s.workout.entries[0], b = s.workout.entries[1]
        s.setWorkingRest(210, entryId: a.id)
        #expect(s.workingRestSeconds(entryId: a.id) == 210)
        #expect(s.workingRestSeconds(entryId: b.id) == 120)
        #expect(s.restSeconds == 120, "the workout default is unchanged")
        #expect(rests.saved.map(\.id) == ["A"])
        #expect(rests.saved.first?.defaultSec == 120, "saved against the workout default")
    }

    @Test func anAbandonedSessionSavesNoRest() {
        let rests = Rests([:])
        let s = make(rests)
        s.abandon()
        s.setWorkingRest(210, entryId: s.workout.entries[0].id)
        #expect(rests.saved.isEmpty, "the local data was wiped under it")
    }

    @Test func theScreenModelEditsThisExercisesRest() {
        let rests = Rests([:])
        let s = make(rests)
        let a = s.workout.entries[0], b = s.workout.entries[1]
        let model = ExerciseScreenModel.workout(s, entryId: a.id)
        model.setRestSeconds(240)
        #expect(model.restSeconds == 240)
        #expect(model.defaultRestSeconds == 120)
        #expect(ExerciseScreenModel.workout(s, entryId: b.id).restSeconds == 120)
    }

    // MARK: Through the app

    @Test func theAppsSessionUsesTheStoreAndTheSuggestion() throws {
        let rig = try GymTestRig.make()
        let env = rig.env
        let push = try #require(try env.routines.all().first { $0.name == "Push + Arms" })
        env.startSession(routine: push)
        let session = try #require(env.session)
        let bench = try #require(session.workout.entries.first { $0.exerciseId == "0025" })
        let fly = try #require(session.workout.entries.first { $0.exerciseId == "0319" })
        let defaultSec = TimeInterval(env.profile.restSec)
        #expect(session.restSeconds == defaultSec)
        #expect(session.workingRestSeconds(entryId: bench.id) == max(defaultSec, 180))
        #expect(session.workingRestSeconds(entryId: fly.id) == min(defaultSec, 90))

        session.setWorkingRest(210, entryId: bench.id)
        #expect(env.exerciseRests.custom("0025") == 210)
        #expect(session.workingRestSeconds(entryId: bench.id) == 210)
        #expect(session.workingRestSeconds(entryId: fly.id) == min(defaultSec, 90))

        env.endSession()
        try env.workouts.discardActive()
        env.startSession(routine: push)
        let next = try #require(env.session)
        let benchAgain = try #require(next.workout.entries.first { $0.exerciseId == "0025" })
        #expect(next.workingRestSeconds(entryId: benchAgain.id) == 210, "remembered in the next workout")
    }
}
