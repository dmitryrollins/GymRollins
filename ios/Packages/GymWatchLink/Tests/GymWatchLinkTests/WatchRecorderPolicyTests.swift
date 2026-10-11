import Foundation
import Testing
@testable import GymWatchLink

@Suite struct WatchRecorderPolicyTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let workoutId = UUID()

    func workout(id: UUID? = nil, startedAt: Date? = nil, pausedAt: Date? = nil) -> WatchWorkout {
        WatchWorkout(id: id ?? workoutId, name: "Push", startedAt: startedAt ?? now.addingTimeInterval(-300),
                     pausedSeconds: 0, pausedAt: pausedAt, next: nil, status: "All sets done", rest: nil,
                     hasPrevious: false, hasNext: false, watchRecordsHealth: false)
    }

    func state(_ workout: WatchWorkout?, ended: WatchEndedWorkout? = nil, health: Bool = true,
               sentAt: Date? = nil) -> WatchState {
        WatchState(sentAt: sentAt ?? now, workout: workout, lastEnded: ended, today: nil, healthEnabled: health)
    }

    func step(_ state: WatchState, _ recorder: WatchRecorderStatus) -> WatchRecorderPolicy.Step {
        WatchRecorderPolicy.step(state: state, recorder: recorder, now: now)
    }

    @Test func aRunningPhoneWorkoutStartsTheSessionAtItsStart() {
        #expect(step(state(workout()), .idle) == .start(workoutId: workoutId, startDate: now.addingTimeInterval(-300)))
    }

    @Test func aLongRunningWorkoutIsJoinedWithABoundedBackdate() {
        let old = workout(startedAt: now.addingTimeInterval(-10 * 3_600))
        #expect(step(state(old), .idle)
            == .start(workoutId: workoutId, startDate: now.addingTimeInterval(-WatchRecorderPolicy.maxBackdate)))
    }

    @Test func aSessionWokenByThePhoneAttachesThenClaims() {
        let woken = WatchRecorderStatus(isRunning: true, startedAt: now)
        #expect(step(state(workout()), woken) == .attach(workoutId: workoutId))
        let attached = WatchRecorderStatus(isRunning: true, workoutId: workoutId, startedAt: now)
        #expect(step(state(workout()), attached) == .claim(workoutId: workoutId))
        #expect(step(state(workout(), health: false), attached) == .none) // Health off in the app: no claim
        let claimed = WatchRecorderStatus(isRunning: true, workoutId: workoutId, startedAt: now, claimSent: true)
        #expect(step(state(workout()), claimed) == .none)
    }

    @Test func pausesFollowThePhone() {
        let claimed = WatchRecorderStatus(isRunning: true, workoutId: workoutId, claimSent: true)
        #expect(step(state(workout(pausedAt: now)), claimed) == .pause)
        let paused = WatchRecorderStatus(isRunning: true, workoutId: workoutId, claimSent: true, isPaused: true)
        #expect(step(state(workout()), paused) == .resume)
    }

    @Test func aFinishedAcceptedWorkoutIsSavedAtThePhonesEnd() {
        let recording = WatchRecorderStatus(isRunning: true, workoutId: workoutId, claimSent: true)
        let endedAt = now.addingTimeInterval(-20)
        let ended = WatchEndedWorkout(workoutId: workoutId, endedAt: endedAt, finished: true, watchRecordsHealth: true)
        #expect(step(state(nil, ended: ended), recording) == .end(save: true, endDate: endedAt))
    }

    @Test func aNotAcceptedOrDiscardedWorkoutIsNotSaved() {
        let recording = WatchRecorderStatus(isRunning: true, workoutId: workoutId, claimSent: true)
        let notAccepted = WatchEndedWorkout(workoutId: workoutId, endedAt: now, finished: true, watchRecordsHealth: false)
        #expect(step(state(nil, ended: notAccepted), recording) == .end(save: false, endDate: now))
        let discarded = WatchEndedWorkout(workoutId: workoutId, endedAt: now.addingTimeInterval(-5), finished: false,
                                          watchRecordsHealth: true)
        #expect(step(state(nil, ended: discarded), recording) == .end(save: false, endDate: now))
        #expect(step(state(nil), recording) == .end(save: false, endDate: now)) // phone forgot it
    }

    @Test func aNewPhoneWorkoutClosesTheOldSessionFirst() {
        let recording = WatchRecorderStatus(isRunning: true, workoutId: workoutId, claimSent: true)
        let ended = WatchEndedWorkout(workoutId: workoutId, endedAt: now.addingTimeInterval(-60), finished: true,
                                      watchRecordsHealth: true)
        #expect(step(state(workout(id: UUID()), ended: ended), recording)
            == .end(save: true, endDate: now.addingTimeInterval(-60)))
    }

    @Test func anOrphanSessionEndsAfterAGracePeriodOfWallClockTime() {
        let woken = WatchRecorderStatus(isRunning: true, startedAt: now.addingTimeInterval(-2))
        #expect(step(state(nil), woken) == .none)
        // Same (old) state, later check: no new push is needed to end it.
        let later = WatchRecorderPolicy.step(state: state(nil, sentAt: now.addingTimeInterval(-60)), recorder: woken,
                                             now: now.addingTimeInterval(WatchRecorderPolicy.orphanGrace))
        #expect(later == .end(save: false, endDate: now.addingTimeInterval(WatchRecorderPolicy.orphanGrace)))
    }

    @Test func aLeftoverSessionIsNotAttachedToALaterWorkout() {
        let leftover = WatchRecorderStatus(isRunning: true, startedAt: now.addingTimeInterval(-3_600))
        #expect(step(state(workout()), leftover) == .end(save: false, endDate: now))
    }

    @Test func nothingToDoWhenIdle() {
        #expect(step(state(nil), .idle) == .none)
    }
}
