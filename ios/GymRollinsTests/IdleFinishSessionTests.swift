import Foundation
import GymCore
import Testing
@testable import GymRollins

/// Finishing long after the last set: the session offers the last set (+ rest) as the end, and finishing there
/// shortens the saved duration and the calorie estimate (what goes to Apple Health).
@MainActor
@Suite struct IdleFinishSessionTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    private final class Saved { var workout: Workout? }
    /// The session's "now", moved by the test (a reference, so the session reads it while a helper moves it).
    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func make(_ time: Clock, saved: Saved = Saved()) -> WorkoutSession {
        let workout = Workout(startedAt: start, name: "Home · KB Upper", entries: [
            WorkoutEntry(exerciseId: "0025", sets: (0..<4).map { _ in WorkoutSet(weightKg: 24, reps: 10) })
        ])
        return WorkoutSession(
            workout: workout, clock: WorkoutClock(startedAt: start), restSeconds: 90, warmupRestSeconds: 60,
            notifier: NoopRestNotifier(), now: { time.now }, persist: { _, _ in }, previousBests: { _ in nil },
            saveFinished: { workout, _ in saved.workout = workout }, discard: {})
    }

    /// Logs the bench sets at 11, 14, 17 and 20 minutes in.
    private func logAll(_ session: WorkoutSession, _ time: Clock) {
        for minute in [11.0, 14, 17, 20] {
            time.now = at(minute)
            session.logNextSet(entryId: session.workout.entries[0].id, weightKg: 24, reps: 10)
        }
    }

    @Test func suggestsTheLastSetPlusRestOnlyWhenIdle() {
        let time = Clock(at(0))
        let s = make(time)
        #expect(s.idleFinishSuggestion() == nil) // nothing logged
        logAll(s, time)
        time.now = at(30)
        #expect(s.idleFinishSuggestion() == nil) // 10 min after the last set
        time.now = at(107)
        #expect(s.idleFinishSuggestion() == at(21.5))
    }

    @Test func finishingAtTheSuggestionShortensDurationAndCalories() throws {
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]))
        let time = Clock(at(0))
        let late = Saved(), early = Saved()
        let lateSession = make(time, saved: late)
        let earlySession = make(time, saved: early)
        logAll(lateSession, time)
        logAll(earlySession, time)
        time.now = at(107)

        let lateSummary = try lateSession.finish(discardingUndone: false)
        let end = try #require(earlySession.idleFinishSuggestion())
        let earlySummary = try earlySession.finish(discardingUndone: false, endingAt: end)

        #expect(lateSummary.durationSeconds == 107 * 60)
        #expect(earlySummary.durationSeconds == 21.5 * 60)
        let saved = try #require(early.workout)
        #expect(saved.endedAt == at(21.5))
        let lateWorkout = try #require(late.workout)
        let lateKcal = try #require(env.calories.estimate(lateWorkout)).kcal
        let earlyKcal = try #require(env.calories.estimate(saved)).kcal
        #expect(earlyKcal < lateKcal)
        #expect(earlyKcal * 4 < lateKcal) // ~21 of ~107 minutes
    }

    /// Paused long after the last set and finished later still: the open pause began after the chosen end, so it
    /// isn't subtracted (the duration is the time up to the end, not negative).
    @Test func endingBeforeAnOpenPauseIgnoresIt() throws {
        let time = Clock(at(0))
        let saved = Saved()
        let s = make(time, saved: saved)
        logAll(s, time)
        time.now = at(60)
        s.togglePause()
        time.now = at(120)
        let end = try #require(s.idleFinishSuggestion())
        #expect(end == at(21.5))
        #expect(s.duration(endingAt: end) == 21.5 * 60)
        let summary = try s.finish(discardingUndone: false, endingAt: end)
        #expect(summary.durationSeconds == 21.5 * 60)
        #expect(saved.workout?.pausedSeconds == 0)
    }

    /// The watch learns the earlier end and when Finish was tapped (its save window runs from the tap).
    @Test func watchEndedWorkoutCarriesTheFinishTime() throws {
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow",
                                                                       "2026-09-26T09:00:00Z"]))
        let begun = env.now().addingTimeInterval(-6_000)
        let workout = Workout(startedAt: begun, endedAt: begun.addingTimeInterval(1_300), name: "Push", entries: [])
        try env.workouts.save(workout, records: [])
        let ended = env.endedWatchWorkout(workout.id)
        #expect(ended.finished)
        #expect(ended.endedAt == begun.addingTimeInterval(1_300))
        #expect(ended.finishedAt == env.now())
    }

    /// "Mark all as done" with an earlier end stamps the undone sets at that end, not after it.
    @Test func markAllDoneAtTheChosenEnd() throws {
        let time = Clock(at(0))
        let s = make(time)
        time.now = at(11)
        s.logNextSet(entryId: s.workout.entries[0].id, weightKg: 24, reps: 10)
        time.now = at(107)
        let end = try #require(s.idleFinishSuggestion())
        s.markAllDone(at: end)
        #expect(s.workout.entries[0].sets.compactMap(\.completedAt).max() == end)
    }
}
