import Foundation
import GymCore
import GymWatchLink
import Testing
@testable import GymRollins

/// The phone applies watch commands once, through `WorkoutSession.perform`, and only while they still apply.
@MainActor
@Suite struct WatchCommandHandlerTests {
    typealias Fixture = WatchSessionActionTests

    final class Recorder {
        var session: WorkoutSession?
        var healthEnabled = true
        var starts = 0
        var claims: [UUID] = []
        var recorded: [UUID] = []
    }

    let clock = Fixture.Clock()
    let recorder = Recorder()
    let suite = "watch-handler-\(UUID())"

    private func makeHandler() -> WatchCommandHandler {
        let defaults = UserDefaults(suiteName: suite)!
        let recorder = self.recorder
        return WatchCommandHandler(defaults: defaults, hooks: WatchCommandHandler.Hooks(
            session: { recorder.session },
            exercise: Fixture.lookup,
            healthEnabled: { recorder.healthEnabled },
            startToday: {
                recorder.starts += 1
                return true
            },
            acceptClaim: { recorder.claims.append($0) },
            recorded: { recorder.recorded.append($0) }))
    }

    private func command(_ action: WatchAction) -> WatchCommand {
        WatchCommand(issuedAt: clock.now, action: action)
    }

    private func logBench(_ s: WorkoutSession, weight: Double, unit: WatchWeightUnit = .lb, reps: Int = 8) -> WatchCommand {
        let entry = s.workout.entries[0]
        let set = entry.sets.first { !$0.done }!
        return command(.logSet(workoutId: s.workout.id, entryId: entry.id, setId: set.id, weight: weight, unit: unit,
                               reps: reps))
    }

    @Test func logSetConvertsTheWatchsUnitAndLogsThroughTheSession() {
        let s = Fixture.makeSession(clock)
        recorder.session = s
        let handler = makeHandler()
        #expect(handler.handle(logBench(s, weight: 145, reps: 6)) == .applied)
        let set = s.workout.entries[0].sets[0]
        #expect(set.done && set.reps == 6)
        #expect(abs(set.weightKg - UnitConverter.toKg(145, from: .lb)) < 1e-9)
    }

    @Test func anUnchangedWeightKeepsThePlannedKilograms() {
        let s = Fixture.makeSession(clock)
        recorder.session = s
        #expect(makeHandler().handle(logBench(s, weight: UnitConverter.fromKg(61.2, to: .lb))) == .applied)
        #expect(s.workout.entries[0].sets[0].weightKg == 61.2)
    }

    @Test func theSameCommandIsAppliedOnceEvenAcrossLaunches() {
        let s = Fixture.makeSession(clock)
        recorder.session = s
        let cmd = logBench(s, weight: 135)
        #expect(makeHandler().handle(cmd) == .applied)
        // transferUserInfo fallback of the same tap, delivered after a relaunch.
        #expect(makeHandler().handle(cmd) == .duplicate)
        #expect(s.workout.entries[0].sets.filter(\.done).count == 1)
    }

    @Test func outOfRangeValuesAreIgnored() {
        let s = Fixture.makeSession(clock)
        recorder.session = s
        let handler = makeHandler()
        #expect(handler.handle(logBench(s, weight: .nan)) == .ignored)
        #expect(handler.handle(logBench(s, weight: 5_000, unit: .kg)) == .ignored)
        #expect(handler.handle(logBench(s, weight: 100, reps: -1)) == .ignored)
        #expect(s.workout.entries[0].sets.allSatisfy { !$0.done })
    }

    @Test func restActionsOnlyApplyToTheRestTheWatchSaw() throws {
        let s = Fixture.makeSession(clock)
        recorder.session = s
        let handler = makeHandler()
        #expect(handler.handle(logBench(s, weight: 135)) == .applied)
        let rest = try #require(s.rest)
        let old = rest.startedAt.addingTimeInterval(-300)
        #expect(handler.handle(command(.extendRest(workoutId: s.workout.id, entryId: nil, restStartedAt: old,
                                                   seconds: 30))) == .ignored)
        #expect(s.rest == rest)
        #expect(handler.handle(command(.extendRest(workoutId: s.workout.id, entryId: nil, restStartedAt: rest.startedAt,
                                                   seconds: 30))) == .applied)
        #expect(s.rest?.duration == rest.duration + 30)
        #expect(handler.handle(command(.skipRest(workoutId: s.workout.id, entryId: nil,
                                                 restStartedAt: rest.startedAt))) == .applied)
        #expect(s.rest == nil)
    }

    @Test func showExerciseGoesThroughTheSession() {
        let s = Fixture.makeSession(clock)
        recorder.session = s
        let ids = s.workout.entries.map(\.id)
        #expect(makeHandler().handle(command(.showExercise(workoutId: s.workout.id, fromEntryId: ids[0],
                                                           direction: .next))) == .applied)
        #expect(s.currentEntryId == ids[1])
    }

    @Test func workoutActionsWithoutASessionAreIgnored() {
        let s = Fixture.makeSession(clock)
        #expect(makeHandler().handle(logBench(s, weight: 135)) == .ignored)
    }

    @Test func startTodayOnlyWhenNoWorkoutRuns() {
        let handler = makeHandler()
        #expect(handler.handle(command(.startToday)) == .applied)
        recorder.session = Fixture.makeSession(clock)
        #expect(handler.handle(command(.startToday)) == .ignored)
        #expect(recorder.starts == 1)
    }

    @Test func healthClaimsAreAcceptedForTheRunningWorkoutWithHealthOn() {
        let s = Fixture.makeSession(clock)
        recorder.session = s
        let handler = makeHandler()
        #expect(handler.handle(command(.healthClaim(workoutId: UUID()))) == .ignored)
        recorder.healthEnabled = false
        #expect(handler.handle(command(.healthClaim(workoutId: s.workout.id))) == .ignored)
        recorder.healthEnabled = true
        #expect(handler.handle(command(.healthClaim(workoutId: s.workout.id))) == .applied)
        #expect(recorder.claims == [s.workout.id])
    }

    @Test func aClaimAfterTheWorkoutFinishedIsRejected() throws {
        let s = Fixture.makeSession(clock)
        recorder.session = s
        _ = try s.finish(discardingUndone: true)
        #expect(makeHandler().handle(command(.healthClaim(workoutId: s.workout.id))) == .ignored)
        #expect(recorder.claims.isEmpty)
    }

    @Test func recordedWorkoutsAndStateRequests() {
        let id = UUID()
        let handler = makeHandler()
        #expect(handler.handle(command(.healthRecorded(workoutId: id, averageHeartRate: 120, maxHeartRate: 150)))
            == .applied)
        #expect(recorder.recorded == [id])
        #expect(handler.handle(command(.requestState)) == .stateRequested)
    }
}
