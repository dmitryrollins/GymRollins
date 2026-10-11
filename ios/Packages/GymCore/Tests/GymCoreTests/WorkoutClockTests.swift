import Foundation
import Testing
@testable import GymCore

@Suite struct WorkoutClockTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func elapsedExcludesPauses() {
        let clock = WorkoutClock(startedAt: t0)
            .pausing(at: t0.addingTimeInterval(600))
            .resuming(at: t0.addingTimeInterval(900))
        #expect(clock.elapsed(at: t0.addingTimeInterval(1_200)) == 900)
        #expect(clock.pausedSeconds == 300)
    }

    @Test func pausedClockStops() {
        let clock = WorkoutClock(startedAt: t0).pausing(at: t0.addingTimeInterval(60))
        #expect(clock.isPaused)
        #expect(clock.elapsed(at: t0.addingTimeInterval(500)) == 60)
    }

    @Test func pauseAndResumeAreIdempotent() {
        let paused = WorkoutClock(startedAt: t0).pausing(at: t0.addingTimeInterval(10))
        #expect(paused.pausing(at: t0.addingTimeInterval(20)) == paused)
        let running = WorkoutClock(startedAt: t0)
        #expect(running.resuming(at: t0.addingTimeInterval(20)) == running)
    }

    @Test func neverNegative() {
        #expect(WorkoutClock(startedAt: t0).elapsed(at: t0.addingTimeInterval(-5)) == 0)
    }

    @Test func formatsClock() {
        #expect(DurationFormatter.clock(1_452) == "24:12")
        #expect(DurationFormatter.clock(3_957) == "1:05:57")
        #expect(DurationFormatter.clock(5) == "0:05")
    }

    @Test func formatsMinutes() {
        #expect(DurationFormatter.minutes(3_957) == "65m")
        #expect(DurationFormatter.minutes(29) == "0m")
    }

    @Test func twoPauseResumeCyclesAccumulatePausedSeconds() {
        let clock = WorkoutClock(startedAt: t0)
            .pausing(at: t0.addingTimeInterval(100))
            .resuming(at: t0.addingTimeInterval(150))
            .pausing(at: t0.addingTimeInterval(300))
            .resuming(at: t0.addingTimeInterval(360))
        #expect(clock.pausedSeconds == 110)
        #expect(clock.elapsed(at: t0.addingTimeInterval(400)) == 290)
    }

    /// Ending now matches resuming first (the open pause counts); ending before the pause began leaves it out.
    @Test func pausedSecondsEndingAt() {
        let paused = WorkoutClock(startedAt: t0, pausedSeconds: 60).pausing(at: t0.addingTimeInterval(1_000))
        #expect(paused.pausedSeconds(endingAt: t0.addingTimeInterval(1_300)) == 360)
        #expect(paused.pausedSeconds(endingAt: t0.addingTimeInterval(500)) == 60)
        #expect(paused.duration(endingAt: t0.addingTimeInterval(500)) == 440)
    }

    /// An end so early that the recorded pauses can't all fit before it: duration bottoms out at zero.
    @Test func durationEndingAtNeverNegative() {
        let clock = WorkoutClock(startedAt: t0, pausedSeconds: 600)
        #expect(clock.pausedSeconds(endingAt: t0.addingTimeInterval(300)) == 300)
        #expect(clock.duration(endingAt: t0.addingTimeInterval(300)) == 0)
        #expect(clock.duration(endingAt: t0.addingTimeInterval(-60)) == 0)
    }

    @Test func formatsHoursAndMinutes() {
        #expect(DurationFormatter.hoursMinutes(5_220) == "1 h 27 min")
        #expect(DurationFormatter.hoursMinutes(7_200) == "2 h")
        #expect(DurationFormatter.hoursMinutes(2_700) == "45 min")
        #expect(DurationFormatter.hoursMinutes(20) == "0 min")
    }
}
