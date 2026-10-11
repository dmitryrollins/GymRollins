import Foundation
import Testing
@testable import GymCore

@Suite struct IdleFinishTests {
    private let start = Date(timeIntervalSince1970: 100_000)
    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    /// The owner's real case: started 19:05, last set 19:25, Finish tapped 20:52.
    @Test func suggestsLastSetPlusRestWhenFinishedLongAfter() {
        let sets = [at(11), at(20), at(15)] // order doesn't matter
        let end = IdleFinish.suggestedEnd(completedAt: sets, clock: WorkoutClock(startedAt: start),
                                          restSeconds: 120, now: at(107))
        #expect(end == at(22))
    }

    @Test func noCompletedSetsOffersNothing() {
        #expect(IdleFinish.suggestedEnd(completedAt: [], clock: WorkoutClock(startedAt: start),
                                        restSeconds: 120, now: at(300)) == nil)
    }

    @Test func thresholdEdges() {
        let clock = WorkoutClock(startedAt: start)
        let last = at(10)
        let atThreshold = last.addingTimeInterval(IdleFinish.minimumIdle)
        #expect(IdleFinish.suggestedEnd(completedAt: [last], clock: clock, restSeconds: 90, now: atThreshold) == nil)
        #expect(IdleFinish.suggestedEnd(completedAt: [last], clock: clock, restSeconds: 90,
                                        now: atThreshold.addingTimeInterval(1)) == last.addingTimeInterval(90))
    }

    /// A long rest setting raises the threshold to rest + margin, so a legit long rest never prompts.
    @Test func longRestRaisesTheThreshold() {
        let clock = WorkoutClock(startedAt: start)
        let last = at(10)
        let rest: TimeInterval = 900
        let edge = last.addingTimeInterval(rest + IdleFinish.restMargin)
        #expect(IdleFinish.suggestedEnd(completedAt: [last], clock: clock, restSeconds: rest, now: edge) == nil)
        #expect(IdleFinish.suggestedEnd(completedAt: [last], clock: clock, restSeconds: rest,
                                        now: edge.addingTimeInterval(1)) == last.addingTimeInterval(rest))
    }

    @Test func shortOrDisabledRestStillAddsAMinute() {
        let end = IdleFinish.suggestedEnd(completedAt: [at(10)], clock: WorkoutClock(startedAt: start),
                                          restSeconds: 0, now: at(60))
        #expect(end == at(11))
    }

    /// Completed pauses may have fallen in the idle gap: they don't count as idle time.
    @Test func completedPausesDontCountAsIdle() {
        let clock = WorkoutClock(startedAt: start, pausedSeconds: 10 * 60)
        #expect(IdleFinish.suggestedEnd(completedAt: [at(10)], clock: clock, restSeconds: 60, now: at(30)) == nil)
        #expect(IdleFinish.suggestedEnd(completedAt: [at(10)], clock: clock, restSeconds: 60, now: at(40)) == at(11))
    }

    /// Paused right after the last set and forgot: the clock already stopped, finishing now is right.
    @Test func pausedSoonAfterTheLastSetOffersNothing() {
        let clock = WorkoutClock(startedAt: start).pausing(at: at(12))
        #expect(IdleFinish.suggestedEnd(completedAt: [at(10)], clock: clock, restSeconds: 60, now: at(200)) == nil)
    }

    /// Paused long after the last set: the idle stretch before the pause is trimmed.
    @Test func pausedLongAfterTheLastSetIsMeasuredToThePause() {
        let clock = WorkoutClock(startedAt: start).pausing(at: at(60))
        #expect(IdleFinish.suggestedEnd(completedAt: [at(10)], clock: clock, restSeconds: 60, now: at(200)) == at(11))
    }

    /// A set stamped before the workout's start (clock skew, an edited start) never yields an end before start.
    @Test func neverBeforeStart() {
        let end = IdleFinish.suggestedEnd(completedAt: [start.addingTimeInterval(-3_600)],
                                          clock: WorkoutClock(startedAt: start), restSeconds: 60, now: at(60))
        #expect(end == start)
    }

    @Test func finishingAtTheSuggestionShortensDurationKeepingEarlierPauses() {
        let clock = WorkoutClock(startedAt: start, pausedSeconds: 120)
        let end = at(22)
        #expect(clock.pausedSeconds(endingAt: end) == 120)
        #expect(clock.duration(endingAt: end) == 20 * 60)
    }
}
