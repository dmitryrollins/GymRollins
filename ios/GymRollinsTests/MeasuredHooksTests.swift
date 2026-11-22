import Foundation
import GymCore
import GymData
import GymHealth
import Testing
@testable import GymRollins

/// Set once a task under test returned.
@MainActor
private final class Finished { var done = false }

/// Plan 40, spec §5.5: a workout's numbers are read and saved without its detail being opened, after the watch saved
/// it, after the phone's export wrote its copy, when plan 39's import attaches or removes a recording, and for the
/// last 90 days once the effort types are allowed. Each waits on the saved row (`waitUntil` from
/// SyncCoordinatorTests, up to 2 s).
@MainActor
@Suite struct MeasuredHooksTests {
    private let id = MeasuredFixture.workoutId

    private func saved(_ env: AppEnvironment, _ workoutId: UUID) -> MeasurementSnapshot? {
        try? env.measurements.snapshot(for: workoutId)
    }

    @Test func theWatchSayingItSavedTheWorkoutReadsItsNumbers() async throws {
        let env = try await MeasuredFixture.environment(FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()]))
        env.watchCommandHooks.recorded(id)
        try await waitUntil { saved(env, id)?.recordedBy == .watch }
        #expect(saved(env, id)?.activeKcal == 412)
    }

    @Test func aWatchMessageBeforeThePhoneSavedTheFinishIsReadOnceItIs() async throws {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store, saved: false)
        let workout = MeasuredFixture.workout()
        try env.workouts.saveActive(workout.with(endedAt: nil, pausedSeconds: 0), pausedAt: nil)
        env.watchCommandHooks.recorded(id)
        for _ in 0..<20 { await Task.yield() }
        #expect(saved(env, id) == nil, "a running workout keeps no row")
        try env.workouts.save(workout) // the phone's Finish
        env.dataChanged()
        try await waitUntil { saved(env, id)?.recordedBy == .watch }
    }

    @Test func thePhonesExportReadsTheWorkoutItWrote() async throws {
        let finished = MeasuredFixture.workout(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000b2")!,
                                               start: MeasuredFixture.now.addingTimeInterval(-3_500))
        let phoneCopy = WorkoutMeasurements(
            recordedBy: .phone, duration: nil, activeKcal: nil, totalKcal: nil,
            heartRate: [HeartRateReading(date: finished.startedAt.addingTimeInterval(900), bpm: 110),
                        HeartRateReading(date: finished.startedAt.addingTimeInterval(1_800), bpm: 120)],
            postWorkout: [], effort: nil)
        let store = FakeHealthStore(measurements: [finished.id: phoneCopy])
        let env = try await MeasuredFixture.environment(store)
        try env.workouts.save(finished) // ends at `now`, after Health was turned on: the phone exports it
        env.dataChanged()
        try await waitUntil { saved(env, finished.id)?.avgHr == 115 }
        #expect(saved(env, finished.id)?.recordedBy == nil, "a phone copy is never measured")
        #expect(saved(env, finished.id)?.activeKcal == nil && saved(env, finished.id)?.durationS == nil)
        #expect(await store.workouts.map(\.externalId) == [finished.id])
    }

    @Test func anAttachedRecordingIsSavedAndItsRemovalToo() async throws {
        let store = FakeHealthStore(outsideWorkouts: FakeHealthStore.uiTestOutsideWorkouts(now: MeasuredFixture.now))
        let env = try await MeasuredFixture.environment(store) // turning Health on imports plan 39's recording
        try await waitUntil { saved(env, id)?.recordedBy == .appleWorkout }
        let attached = try #require(saved(env, id))
        #expect(attached.activeKcal == 412 && attached.avgHr == 128 && attached.maxHr == 162)
        await store.deleteOutsideWorkout(FakeHealthStore.uiTestStrengthId)
        await env.health.importActivity()
        try await waitUntil { saved(env, id)?.recordedBy == nil }
        #expect(saved(env, id)?.activeKcal == nil, "the cloud stops seeing it")
    }

    @Test func turningHealthOnReadsTheLast90DaysOnceOnTheNextSync() async throws {
        let older = MeasuredFixture.workout(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000b3")!,
                                            start: ISO8601DateFormatter().date(from: "2026-05-02T18:00:00Z")!)
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy(),
                                                   older.id: MeasuredFixture.watchCopy(start: older.startedAt)])
        let env = try await MeasuredFixture.environment(store) // Settings' turn-on: enable() asks for every type
        try env.workouts.save(older)
        #expect(saved(env, id) == nil, "turning Health on reads nothing itself")
        await env.syncHealth() // the next launch or foreground
        #expect(saved(env, id)?.recordedBy == .watch, "19 Sep is within 90 days of 26 Sep")
        #expect(saved(env, older.id) == nil, "2 May is older: it's read when its detail opens")
        await store.setWorkoutMeasurements(MeasuredFixture.watchCopy(effort: Effort(score: 5, estimated: true)), for: id)
        await env.syncHealth()
        #expect(saved(env, id)?.effort == nil, "once per account: the next sync doesn't read it again")
    }

    @Test func aBackfillReadRunningWhenTheAppComesBackIsStillSaved() async throws {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store)
        await store.setGate(true) // holds the read open
        let backfill = Task { await env.backfillMeasurementsOnce() }
        try await waitUntil { await store.parkedCount == 1 }
        env.measuredMemo.forgetAll() // what `syncHealth()` does first on a return to the foreground
        await store.setGate(false)
        await backfill.value
        #expect(saved(env, id)?.recordedBy == .watch)
    }

    @Test func theBackfillIsMarkedDoneOnlyOnceItsReadsAreSaved() async throws {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store)
        await store.setGate(true) // holds the read open
        let backfill = Task { await env.backfillMeasurementsOnce() }
        try await waitUntil { await store.parkedCount == 1 }
        #expect(env.defaults.string(forKey: AppEnvironment.measuredBackfillKey) == nil,
                "killed now, the next launch reads them again")
        await store.setGate(false)
        await backfill.value
        #expect(env.defaults.string(forKey: AppEnvironment.measuredBackfillKey) == "local")
        #expect(saved(env, id)?.recordedBy == .watch)
    }

    @Test func aSecondBackfillWhileOneRunsReadsNothing() async throws {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store)
        await store.setGate(true) // holds the first one's read open
        let first = Task { await env.backfillMeasurementsOnce() }
        try await waitUntil { await store.parkedCount == 1 }
        let second = Finished()
        let other = Task {
            await env.backfillMeasurementsOnce() // the Allow pill while the sync's runs
            second.done = true
        }
        try await waitUntil {
            if second.done { return true }
            return await store.parkedCount > 1
        }
        let parked = await store.parkedCount
        #expect(second.done && parked == 1, "only the running one reads")
        await store.setGate(false)
        await first.value
        await other.value
        #expect(saved(env, id)?.recordedBy == .watch)
    }

    @Test func theAllowPillReadsTheLast90DaysWhenTheSyncCouldNot() async throws {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store)
        await store.setEffortAsked(false) // Health was turned on by build 4, before the effort types
        await env.syncHealth()
        #expect(env.health.effortNeedsAsking, "the Allow pill shows")
        #expect(saved(env, id) == nil, "no read before the effort types are asked")
        await env.allowHealthEffort()
        #expect(!env.health.effortNeedsAsking)
        #expect(saved(env, id)?.recordedBy == .watch)
    }
}
