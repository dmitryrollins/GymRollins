import Foundation
import Observation
import Testing
@testable import GymWatchLink

/// Codex review of plan 17: an orphan session with no phone state, a "Logging…" that must clear by itself and stale
/// states never renaming the recorder.
@MainActor
@Suite struct WatchReviewFixTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let workoutId = UUID()

    // MARK: Orphan session without any phone state (finding 2)

    @Test func aWokenSessionWithNoPhoneStateEverEndsUnsavedAfterTheGrace() {
        let woken = WatchRecorderStatus(isRunning: true, startedAt: now)
        #expect(WatchRecorderPolicy.step(state: nil, recorder: woken, now: now.addingTimeInterval(2)) == .none)
        let later = now.addingTimeInterval(WatchRecorderPolicy.orphanGrace)
        #expect(WatchRecorderPolicy.step(state: nil, recorder: woken, now: later) == .end(save: false, endDate: later))
    }

    @Test func withoutAPhoneStateAnAttachedOrIdleSessionIsLeftAlone() {
        let attached = WatchRecorderStatus(isRunning: true, workoutId: workoutId, startedAt: now)
        #expect(WatchRecorderPolicy.step(state: nil, recorder: attached, now: now.addingTimeInterval(3_600)) == .none)
        #expect(WatchRecorderPolicy.step(state: nil, recorder: .idle, now: now) == .none)
    }

    @Test func anUnattachedSessionIsRecheckedUntilTheGraceEnds() {
        let woken = WatchRecorderStatus(isRunning: true, startedAt: now)
        let first = WatchRecorderPolicy.recheckDelay(recorder: woken, now: now.addingTimeInterval(4))
        #expect(first == WatchRecorderPolicy.orphanGrace - 4 + WatchRecorderPolicy.recheckMargin)
        // Past the grace (e.g. the recorder was busy at the last check): look again soon, never "never".
        #expect(WatchRecorderPolicy.recheckDelay(recorder: woken, now: now.addingTimeInterval(60))
            == WatchRecorderPolicy.recheckMargin)
        let attached = WatchRecorderStatus(isRunning: true, workoutId: workoutId, startedAt: now)
        #expect(WatchRecorderPolicy.recheckDelay(recorder: attached, now: now) == nil)
        #expect(WatchRecorderPolicy.recheckDelay(recorder: .idle, now: now) == nil)
    }

    @Test func aRecoveredSessionGetsItsGraceFromRecoveryNotFromItsOriginalStart() {
        // HealthKit recovered a workout started 40 min ago; no phone state yet.
        let recovered = WatchRecorderStatus(isRunning: true, startedAt: now.addingTimeInterval(-2_400),
                                            unattachedSince: now)
        #expect(WatchRecorderPolicy.step(state: nil, recorder: recovered, now: now) == .none)
        #expect(WatchRecorderPolicy.recheckDelay(recorder: recovered, now: now)
            == WatchRecorderPolicy.orphanGrace + WatchRecorderPolicy.recheckMargin)
        let noWorkout = WatchState(sentAt: now, workout: nil, lastEnded: nil, today: nil, healthEnabled: true)
        #expect(WatchRecorderPolicy.step(state: noWorkout, recorder: recovered, now: now.addingTimeInterval(2)) == .none)
        let later = now.addingTimeInterval(WatchRecorderPolicy.orphanGrace)
        #expect(WatchRecorderPolicy.step(state: nil, recorder: recovered, now: later) == .end(save: false, endDate: later))
        // Its own phone workout (started before the session) arriving late still attaches it.
        let workout = WatchWorkout(id: workoutId, name: "Push", startedAt: now.addingTimeInterval(-2_500),
                                   pausedSeconds: 0, pausedAt: nil, next: nil, status: "Set 1/3", rest: nil,
                                   hasPrevious: false, hasNext: true, watchRecordsHealth: false)
        let phone = WatchState(sentAt: now, workout: workout, lastEnded: nil, today: nil, healthEnabled: true)
        #expect(WatchRecorderPolicy.step(state: phone, recorder: recovered, now: now) == .attach(workoutId: workoutId))
    }

    // MARK: Recorder name only from an accepted state of its own workout (finding 5)

    func state(sentAt: Date, workoutId: UUID? = nil, name: String = "Push") -> WatchState {
        let workout = WatchWorkout(id: workoutId ?? self.workoutId, name: name, startedAt: now.addingTimeInterval(-60),
                                   pausedSeconds: 0, pausedAt: nil, next: nil, status: "All sets done", rest: nil,
                                   hasPrevious: false, hasNext: false, watchRecordsHealth: false)
        return WatchState(sentAt: sentAt, workout: workout, lastEnded: nil, today: nil, healthEnabled: true)
    }

    @Test func receiveSaysWhetherTheStateWasAccepted() {
        let model = WatchWorkoutModel(sender: FakeSender(), now: { [now] in now })
        #expect(model.receive(state(sentAt: now)))
        #expect(!model.receive(state(sentAt: now.addingTimeInterval(-5), name: "Stale")))
        #expect(model.workout?.name == "Push")
        #expect(model.receive(state(sentAt: now.addingTimeInterval(1), name: "Push (renamed)")))
    }

    @Test func theRecorderTakesTheNameOfItsOwnWorkoutOnly() {
        let recording = WatchRecorderStatus(isRunning: true, workoutId: workoutId, startedAt: now)
        #expect(WatchRecorderPolicy.recordingName(state: state(sentAt: now, name: "Legs"), recorder: recording)
            == "Legs")
        // Another workout's state (the phone moved on) must not rename the session it's about to close.
        #expect(WatchRecorderPolicy.recordingName(state: state(sentAt: now, workoutId: UUID()), recorder: recording)
            == nil)
        #expect(WatchRecorderPolicy.recordingName(state: state(sentAt: now), recorder: .idle) == nil)
        let woken = WatchRecorderStatus(isRunning: true, startedAt: now)
        #expect(WatchRecorderPolicy.recordingName(state: state(sentAt: now), recorder: woken) == nil)
    }

    // MARK: "Logging…" clears by itself (finding 3)

    final class Clock { var now = Date(timeIntervalSince1970: 1_790_000_000) }

    /// Sleeps until the test fires it.
    @MainActor
    final class ManualSleeper {
        private(set) var requested: [TimeInterval] = []
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func sleep(_ seconds: TimeInterval) async throws {
            requested.append(seconds)
            await withCheckedContinuation { waiting.append($0) }
            try Task.checkCancellation()
        }

        /// Lets the model's timeout task run up to its sleep.
        func untilParked(_ count: Int = 1) async {
            for _ in 0..<1_000 where waiting.count < count { await Task.yield() }
        }

        func fire() {
            let parked = waiting
            waiting = []
            parked.forEach { $0.resume() }
        }
    }

    func loggableState(sentAt: Date) -> WatchState {
        let next = WatchNextSet(entryId: UUID(), setId: UUID(), exerciseName: "Bench", setLabel: "Set 1/3",
                                setDetail: "135 lb × 8", canLog: true, weight: 135, reps: 8,
                                grid: WatchLoadGrid(unit: .lb, step: 10, offset: 5))
        let workout = WatchWorkout(id: workoutId, name: "Push", startedAt: sentAt.addingTimeInterval(-600),
                                   pausedSeconds: 0, pausedAt: nil, next: next, status: "Set 1/3", rest: nil,
                                   hasPrevious: false, hasNext: true, watchRecordsHealth: false)
        return WatchState(sentAt: sentAt, workout: workout, lastEnded: nil, today: nil, healthEnabled: true)
    }

    @Test func anUnansweredLogSetStopsShowingLoggingWhenTheTimeoutPassesAndTheViewHearsIt() async {
        let clock = Clock()
        let sleeper = ManualSleeper()
        let model = WatchWorkoutModel(sender: FakeSender(), now: { [clock] in clock.now },
                                      sleep: { try await sleeper.sleep($0) })
        model.receive(loggableState(sentAt: clock.now))
        model.logSet()
        #expect(model.isLogging)
        await sleeper.untilParked()
        #expect(sleeper.requested == [WatchWorkoutModel.pendingTimeout])

        final class Flag: @unchecked Sendable { var raised = false }
        let invalidated = Flag()
        withObservationTracking { _ = model.isLogging } onChange: { invalidated.raised = true }
        clock.now = clock.now.addingTimeInterval(WatchWorkoutModel.pendingTimeout)
        sleeper.fire()
        await model.pendingExpiry?.value
        #expect(invalidated.raised, "SwiftUI must be told the wait is over")
        #expect(!model.isLogging)
    }

    @Test func thePhonesAnswerCancelsThePendingTimeout() async {
        let clock = Clock()
        let sleeper = ManualSleeper()
        let model = WatchWorkoutModel(sender: FakeSender(), now: { [clock] in clock.now },
                                      sleep: { try await sleeper.sleep($0) })
        model.receive(loggableState(sentAt: clock.now))
        model.logSet()
        await sleeper.untilParked()
        let expiry = model.pendingExpiry
        model.receive(loggableState(sentAt: clock.now.addingTimeInterval(1)))
        #expect(!model.isLogging)
        #expect(model.pendingExpiry == nil)
        sleeper.fire()
        await expiry?.value // cancelled: finishes without touching a later wait
        model.logSet()
        #expect(model.isLogging)
    }
}
