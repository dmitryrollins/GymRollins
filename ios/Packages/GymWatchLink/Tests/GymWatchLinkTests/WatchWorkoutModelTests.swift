import Foundation
import Testing
@testable import GymWatchLink

@MainActor
final class FakeSender: WatchCommandSending {
    var isReachable = true
    var sent: [(command: WatchCommand, reachableOnly: Bool)] = []

    func send(_ command: WatchCommand, reachableOnly: Bool) -> Bool {
        guard isReachable || !reachableOnly else { return false }
        sent.append((command, reachableOnly))
        return true
    }

    var actions: [WatchAction] { sent.map(\.command.action) }
}

@MainActor
@Suite struct WatchWorkoutModelTests {
    final class Clock { var now = Date(timeIntervalSince1970: 1_790_000_000) }

    let clock = Clock()
    let sender = FakeSender()
    let workoutId = UUID()
    let entryId = UUID()
    let setId = UUID()

    func makeModel() -> WatchWorkoutModel {
        WatchWorkoutModel(sender: sender, now: { [clock] in clock.now })
    }

    func state(setId: UUID? = nil, rest: WatchRest? = nil, sentAt: Date? = nil, canLog: Bool = true,
               pausedAt: Date? = nil) -> WatchState {
        let next = WatchNextSet(entryId: entryId, setId: setId ?? self.setId, exerciseName: "Bench", setLabel: "Set 1/3",
                                setDetail: "135 lb × 8", canLog: canLog, weight: 135, reps: 8,
                                grid: WatchLoadGrid(unit: .lb, step: 10, offset: 5))
        let workout = WatchWorkout(id: workoutId, name: "Push", startedAt: clock.now.addingTimeInterval(-600),
                                   pausedSeconds: 60, pausedAt: pausedAt, next: next, status: "Set 1/3", rest: rest,
                                   hasPrevious: false, hasNext: true, watchRecordsHealth: false)
        return WatchState(sentAt: sentAt ?? clock.now, workout: workout, lastEnded: nil, today: nil, healthEnabled: true)
    }

    @Test func logSetSendsThePlannedValuesWithTheSetIds() throws {
        let model = makeModel()
        model.receive(state())
        model.logSet()
        let action = try #require(sender.actions.first)
        #expect(action == .logSet(workoutId: workoutId, entryId: entryId, setId: setId, weight: 135, unit: .lb, reps: 8))
        #expect(sender.sent.first?.reachableOnly == false) // queued when the phone isn't reachable
    }

    @Test func crownEditsAreLoggedAndResetForTheNextSet() throws {
        let model = makeModel()
        model.receive(state())
        model.stepWeight(by: 1)
        model.stepReps(by: -2)
        #expect(model.weight == 145)
        #expect(model.reps == 6)
        model.logSet()
        #expect(sender.actions.last == .logSet(workoutId: workoutId, entryId: entryId, setId: setId, weight: 145,
                                               unit: .lb, reps: 6))
        model.receive(state(setId: UUID(), sentAt: clock.now.addingTimeInterval(1)))
        #expect(model.weight == 135)
        #expect(model.reps == 8)
    }

    @Test func aDoubleTapLogsOnceUntilThePhoneAnswers() {
        let model = makeModel()
        model.receive(state())
        model.logSet()
        model.logSet()
        #expect(sender.sent.count == 1)
        #expect(model.isLogging)
        clock.now = clock.now.addingTimeInterval(WatchWorkoutModel.pendingTimeout + 1)
        model.logSet() // the phone never answered: allow a retry (the phone ignores a duplicate anyway)
        #expect(sender.sent.count == 2)
    }

    @Test func thePhonesAnswerEndsTheWaitEvenWhenTheTapDidntApply() {
        let model = makeModel()
        model.receive(state())
        model.logSet()
        #expect(model.isLogging)
        model.receive(state(sentAt: clock.now.addingTimeInterval(1))) // same set: the phone ignored it
        #expect(!model.isLogging)
    }

    @Test func nonRepsSetsCantBeLoggedFromTheWatch() {
        let model = makeModel()
        model.receive(state(canLog: false))
        model.logSet()
        #expect(sender.sent.isEmpty)
    }

    @Test func restActionsCarryTheRestTheyAppliedTo() {
        let model = makeModel()
        let rest = WatchRest(startedAt: clock.now, endsAt: clock.now.addingTimeInterval(90))
        model.receive(state(rest: rest))
        model.addRest()
        model.skipRest()
        #expect(sender.actions == [
            .extendRest(workoutId: workoutId, entryId: entryId, restStartedAt: rest.startedAt,
                        seconds: WatchWorkoutModel.extraRest),
            .skipRest(workoutId: workoutId, entryId: entryId, restStartedAt: rest.startedAt)
        ])
    }

    @Test func restActionsNeedARunningRest() {
        let model = makeModel()
        model.receive(state())
        model.addRest()
        model.skipRest()
        #expect(sender.sent.isEmpty)
    }

    @Test func exerciseNavigationNamesTheShownEntry() {
        let model = makeModel()
        model.receive(state())
        model.show(.next)
        model.show(.previous) // no previous exercise: nothing sent
        #expect(sender.actions == [.showExercise(workoutId: workoutId, fromEntryId: entryId, direction: .next)])
    }

    @Test func startTodayNeedsAReachablePhone() {
        let model = makeModel()
        sender.isReachable = false
        model.startToday()
        #expect(sender.sent.isEmpty)
        #expect(model.notice == WatchWorkoutModel.openPhoneNotice)
        sender.isReachable = true
        model.startToday()
        #expect(sender.actions == [.startToday])
        #expect(sender.sent.first?.reachableOnly == true)
        #expect(model.notice == nil)
    }

    @Test func olderStatesAreIgnored() {
        let model = makeModel()
        model.receive(state(sentAt: clock.now))
        model.receive(WatchState(sentAt: clock.now.addingTimeInterval(-5), workout: nil, lastEnded: nil, today: nil,
                                 healthEnabled: false))
        #expect(model.workout?.id == workoutId)
    }

    @Test func restCountdownAndOneHapticPerRest() {
        let model = makeModel()
        let rest = WatchRest(startedAt: clock.now, endsAt: clock.now.addingTimeInterval(90))
        model.receive(state(rest: rest))
        #expect(model.restRemaining(at: clock.now.addingTimeInterval(30)) == 60)
        #expect(!model.takeRestFinished(at: clock.now.addingTimeInterval(89)))
        #expect(model.takeRestFinished(at: clock.now.addingTimeInterval(90)))
        #expect(!model.takeRestFinished(at: clock.now.addingTimeInterval(95)))
        #expect(model.restRemaining(at: clock.now.addingTimeInterval(95)) == nil)
    }

    @Test func aSkippedRestNeverBuzzes() {
        let model = makeModel()
        let rest = WatchRest(startedAt: clock.now, endsAt: clock.now.addingTimeInterval(90))
        model.receive(state(rest: rest))
        model.receive(state(sentAt: clock.now.addingTimeInterval(10)))
        #expect(!model.takeRestFinished(at: clock.now.addingTimeInterval(100)))
    }

    @Test func workoutClockExcludesPauses() {
        let model = makeModel()
        model.receive(state())
        #expect(model.elapsed(at: clock.now) == 540) // 600 s since start − 60 s paused
        let pausedAt = clock.now.addingTimeInterval(-100)
        model.receive(state(sentAt: clock.now.addingTimeInterval(1), pausedAt: pausedAt))
        #expect(model.elapsed(at: clock.now.addingTimeInterval(500)) == 440) // frozen at the pause
    }

    @Test func healthMessagesAreQueued() {
        let model = makeModel()
        model.sendHealthClaim(workoutId: workoutId)
        model.sendHealthRecorded(workoutId: workoutId, averageHeartRate: 120, maxHeartRate: 160)
        #expect(sender.actions == [.healthClaim(workoutId: workoutId),
                                   .healthRecorded(workoutId: workoutId, averageHeartRate: 120, maxHeartRate: 160)])
        #expect(sender.sent.allSatisfy { !$0.reachableOnly })
    }
}
