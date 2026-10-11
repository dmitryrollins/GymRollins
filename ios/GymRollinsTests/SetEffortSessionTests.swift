import Foundation
import GymCore
import Testing
@testable import GymRollins

/// The "Reps left?" chips in the live workout: rating a logged set through the session / exercise screen model.
@MainActor
@Suite struct SetEffortSessionTests {
    final class Spy {
        var persisted: [Workout] = []
        var scheduled: [Date] = []
    }
    struct SpyNotifier: RestNotifier {
        let spy: Spy
        func schedule(endsAt: Date) { spy.scheduled.append(endsAt) }
        func cancel() {}
    }

    private func make(_ spy: Spy, now: Date = Date(timeIntervalSince1970: 1_100)) -> WorkoutSession {
        let workout = Workout(startedAt: Date(timeIntervalSince1970: 1_000), name: "Push", entries: [
            WorkoutEntry(exerciseId: "0025", sets: [
                WorkoutSet(weightKg: 20.41, reps: 10, warmup: true),
                WorkoutSet(weightKg: 61.2, reps: 8),
                WorkoutSet(weightKg: 61.2, reps: 8),
            ]),
        ])
        return WorkoutSession(
            workout: workout, clock: WorkoutClock(startedAt: workout.startedAt),
            restSeconds: 120, warmupRestSeconds: 60, notifier: SpyNotifier(spy: spy), now: { now },
            persist: { w, _ in spy.persisted.append(w) }, previousBests: { _ in nil },
            saveFinished: { _, _ in }, discard: {})
    }

    private func logWarmupAndFirstSet(_ s: WorkoutSession) -> UUID {
        let entryId = s.workout.entries[0].id
        s.logNextSet(entryId: entryId, weightKg: 20.41, reps: 10)
        s.logNextSet(entryId: entryId, weightKg: 61.2, reps: 8)
        return entryId
    }

    @Test func oneTapStoresTheRatingAndKeepsTheRestRunning() throws {
        let spy = Spy()
        let s = make(spy)
        let entryId = logWarmupAndFirstSet(s)
        let rest = try #require(s.rest)
        let set = s.workout.entries[0].sets[1]
        let before = spy.persisted.count

        s.rateSet(entryId: entryId, setId: set.id, tapping: 2)

        #expect(s.workout.entries[0].sets[1].rir == 2)
        #expect(s.workout.entries[0].sets[1].done)
        #expect(s.rest == rest)                         // same timer, not restarted or cleared
        #expect(spy.scheduled.count == 2)               // no extra rest notification
        #expect(spy.persisted.count == before + 1)      // saved like any other edit
        #expect(spy.persisted.last?.entries[0].sets[1].rir == 2)
    }

    @Test func tappingTheSelectedChipClearsAndFourPlusStoresFour() {
        let s = make(Spy())
        let entryId = logWarmupAndFirstSet(s)
        let setId = s.workout.entries[0].sets[1].id
        s.rateSet(entryId: entryId, setId: setId, tapping: 2)
        s.rateSet(entryId: entryId, setId: setId, tapping: 2)
        #expect(s.workout.entries[0].sets[1].rir == nil)
        s.rateSet(entryId: entryId, setId: setId, tapping: 4)
        #expect(s.workout.entries[0].sets[1].rir == 4)
    }

    @Test func warmupsAndUndoneSetsAreNotRated() {
        let spy = Spy()
        let s = make(spy)
        let entryId = logWarmupAndFirstSet(s)
        let before = spy.persisted.count
        s.rateSet(entryId: entryId, setId: s.workout.entries[0].sets[0].id, tapping: 3) // warm-up
        s.rateSet(entryId: entryId, setId: s.workout.entries[0].sets[2].id, tapping: 3) // not logged yet
        #expect(s.workout.entries[0].sets.allSatisfy { $0.rir == nil })
        #expect(spy.persisted.count == before)
    }

    @Test func screenModelPromptsOnlyAfterTheLastSetOfRepsExercises() {
        let s = make(Spy())
        let entryId = s.workout.entries[0].id
        let model = ExerciseScreenModel.workout(s, entryId: entryId)
        #expect(model.effortPromptSetId(mode: .reps) == nil)
        s.logNextSet(entryId: entryId, weightKg: 20.41, reps: 10)
        #expect(model.effortPromptSetId(mode: .reps) == nil) // a warm-up isn't rated
        s.logNextSet(entryId: entryId, weightKg: 61.2, reps: 8)
        #expect(model.effortPromptSetId(mode: .reps) == nil) // one working set still to do
        s.logNextSet(entryId: entryId, weightKg: 61.2, reps: 8)
        let last = s.workout.entries[0].sets[2]
        #expect(model.effortPromptSetId(mode: .reps) == last.id)
        #expect(model.effortPromptSetId(mode: .time) == nil)
        model.rateSet(last, tapping: 1)
        #expect(s.workout.entries[0].sets[2].rir == 1)
    }

    @Test func aRatingFromTheChipsLowersTheRecoveryLoad() throws {
        let s = make(Spy())
        let entryId = s.workout.entries[0].id
        s.logAllSets(entryId: entryId)
        let bench = Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell",
                             target: "pectorals")
        let unrated = MuscleLoads.of(s.workout) { $0 == "0025" ? bench : nil }
        s.rateSet(entryId: entryId, setId: s.workout.entries[0].sets[2].id, tapping: 3)
        let rated = MuscleLoads.of(s.workout) { $0 == "0025" ? bench : nil }
        let group = try #require(unrated.keys.first)
        #expect((unrated[group]?.load ?? 0) - (rated[group]?.load ?? 0) > 0.2) // 1 → 0.75 for that set
        #expect(unrated[group]?.sets == rated[group]?.sets) // still a hard set
    }

    @Test func chipTextAndVoiceOverLabels() {
        #expect(SetEffort.choices.map(SetEffortText.title) == ["0", "1", "2", "3", "4+"])
        #expect(SetEffortText.accessibilityLabel(2) == "2 reps left")
        #expect(SetEffortText.accessibilityLabel(1) == "1 rep left")
        #expect(SetEffortText.accessibilityLabel(0) == "0 reps left, failure")
        #expect(SetEffortText.accessibilityLabel(4) == "4 or more reps left")
    }
}
