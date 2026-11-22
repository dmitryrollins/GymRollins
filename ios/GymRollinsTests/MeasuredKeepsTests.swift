import Foundation
import GymCore
import GymData
import GymHealth
import Testing
@testable import GymRollins

/// Plan 40's review fixes for a workout's saved Health numbers: an empty Health answer (read access taken away, a new
/// phone before Health's iCloud sync) keeps what was measured, and only the app's rating path or a recording removed by
/// plan 39's import changes it; the 90-day read is marked done only when Health answered, for the account it ran for;
/// a sign-out or an account switch forgets the session's reads; and a return to the foreground redraws an open detail.
@MainActor
@Suite struct MeasuredKeepsTests {
    private let id = MeasuredFixture.workoutId
    private let workout = MeasuredFixture.workout()

    private func saved(_ env: AppEnvironment) throws -> MeasurementSnapshot? {
        try env.measurements.snapshot(for: id)
    }

    /// The watch's numbers read and saved, then Health answering with nothing for the workout.
    private func environmentWithSavedWatchNumbers() async throws -> (AppEnvironment, FakeHealthStore) {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store)
        _ = await env.measuredSummary(for: workout)
        #expect(try saved(env)?.recordedBy == .watch)
        await store.setWorkoutMeasurements(WorkoutMeasurements.none, for: id)
        return (env, store)
    }

    // MARK: An empty read

    @Test func anEmptyReadKeepsTheSavedWatchNumbers() async throws {
        let (env, _) = try await environmentWithSavedWatchNumbers()
        let before = try #require(try saved(env))
        await env.refreshMeasurements(for: [id]) // a hook's re-read
        #expect(try saved(env) == before, "the cloud and agents keep what was measured")
        // The detail shows the kept row too, not the estimate the empty read would give.
        let shown = await env.measuredSummary(for: workout)
        #expect(shown.source == .watch && shown.workoutTime == 3_500)
        #expect(shown.activeKcal == 412 && shown.totalKcal == 489 && shown.estimatedKcal == nil)
        #expect(shown.avgHr == 128 && shown.maxHr == 136 && shown.postHr == 124)
        #expect(shown.heartRate.isEmpty && shown.postWorkout.isEmpty, "no readings: no charts")
        #expect(env.immediateMeasuredSummary(for: workout) == shown)
    }

    @Test func anEmptyReadKeepsAWatchRowEvenWhenAskedToClear() async throws {
        let (env, _) = try await environmentWithSavedWatchNumbers()
        let before = try #require(try saved(env))
        await env.refreshMeasurements(for: [id], clearsWhenEmpty: true)
        #expect(try saved(env) == before, "only a recording's own numbers are cleared")
    }

    /// A row saved from an attached recording: kept by an empty read (the import hook's newly attached ids are read
    /// that way), cleared only when the hook saw that recording go.
    @Test func aRecordingsRowIsClearedOnlyWhenItsRecordingWent() async throws {
        let env = try await MeasuredFixture.environment(FakeHealthStore())
        let recording = MeasurementSnapshot(workoutId: id, recordedBy: .appleWorkout, durationS: 3_180, activeKcal: 402,
                                            totalKcal: nil, avgHr: 126, maxHr: 158, postHr: nil, effort: nil,
                                            effortEstimated: false, clientUpdatedAt: MeasuredFixture.now)
        #expect(try env.measurements.save(recording))
        await env.refreshMeasurements(for: [id])
        #expect(try saved(env)?.sameNumbers(as: recording) == true, "an empty read keeps it")
        let shown = await env.measuredSummary(for: workout)
        #expect(shown.source == .attached(sourceName: "Apple Health") && shown.activeKcal == 402)
        await env.refreshMeasurements(for: [id], clearsWhenEmpty: true)
        #expect(try saved(env)?.recordedBy == nil && saved(env)?.activeKcal == nil, "its recording went: cleared")
    }

    @Test func theImportHookClearsOnlyWhatLostItsRecording() {
        let kept = UUID(uuidString: "00000000-0000-4000-8000-0000000000c2")!
        let lost = UUID(uuidString: "00000000-0000-4000-8000-0000000000c3")!
        let gained = UUID(uuidString: "00000000-0000-4000-8000-0000000000c4")!
        let changes = AppEnvironment.attachmentChanges(from: [kept, lost], to: [kept, gained])
        #expect(changes.lost == [lost], "read with clearsWhenEmpty")
        #expect(changes.gained == [gained], "read without it: a newly attached id never clears")
        #expect(AppEnvironment.attachmentChanges(from: [], to: [kept]).lost.isEmpty)
    }

    /// Plan 39's recording leaves the phone's Health while the watch's copy hasn't arrived there either (a new phone,
    /// read access taken away): the saved watch row stays.
    @Test func aLostAttachmentKeepsASavedWatchRow() async throws {
        let store = FakeHealthStore(outsideWorkouts: FakeHealthStore.uiTestOutsideWorkouts(now: MeasuredFixture.now),
                                    measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store) // turning Health on imports and attaches the recording
        try await waitUntil { (try? saved(env))?.recordedBy == .watch }
        let before = try #require(try saved(env))
        await store.setWorkoutMeasurements(WorkoutMeasurements.none, for: id)
        await store.deleteOutsideWorkout(FakeHealthStore.uiTestStrengthId)
        let revision = env.measuredRevision
        await env.health.importActivity()
        try await waitUntil { env.measuredRevision > revision } // the hook's re-read finished
        #expect(try saved(env) == before)
    }

    @Test func anEmptyReadKeepsTheNumbersAndTheAppsRating() async throws {
        let (env, _) = try await environmentWithSavedWatchNumbers()
        #expect(await env.rateEffort(7, for: workout) == .savedInAppOnly, "no copy in Health to relate it to")
        let rated = try #require(try saved(env))
        #expect(rated.recordedBy == .watch && rated.activeKcal == 412 && rated.totalKcal == 489)
        #expect(rated.avgHr == 128 && rated.maxHr == 136 && rated.durationS == 3_500)
        #expect(rated.effort == 7 && !rated.effortEstimated)
        await env.refreshMeasurements(for: [id])
        #expect(try saved(env)?.sameNumbers(as: rated) == true)
    }

    @Test func clearingTheRatingKeepsTheNumbers() async throws {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store)
        _ = await env.measuredSummary(for: workout)
        #expect(await env.rateEffort(7, for: workout) == .saved)
        await store.setWorkoutMeasurements(WorkoutMeasurements.none, for: id)
        await env.clearEffort(for: workout)
        let cleared = try #require(try saved(env))
        #expect(cleared.recordedBy == .watch && cleared.activeKcal == 412 && cleared.maxHr == 136)
        #expect(cleared.effort == nil)
    }

    @Test func aRemovedRecordingClearsItsNumbersAndKeepsTheAppsRating() async throws {
        let store = FakeHealthStore(outsideWorkouts: FakeHealthStore.uiTestOutsideWorkouts(now: MeasuredFixture.now))
        let env = try await MeasuredFixture.environment(store) // turning Health on imports plan 39's recording
        try await waitUntil { (try? saved(env))?.recordedBy == .appleWorkout }
        _ = await env.rateEffort(6, for: workout)
        await store.deleteOutsideWorkout(FakeHealthStore.uiTestStrengthId)
        await env.health.importActivity()
        try await waitUntil { (try? saved(env))?.recordedBy == nil }
        let row = try #require(try saved(env))
        #expect(row.activeKcal == nil && row.durationS == nil && row.avgHr == nil, "the cloud stops seeing it")
        #expect(row.effort == 6)
    }

    // MARK: The 90-day read

    @Test func aBackfillWhoseReadsAllFailedRunsAgain() async throws {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store)
        await store.setFailReads(true)
        await env.backfillMeasurementsOnce()
        #expect(env.defaults.string(forKey: AppEnvironment.measuredBackfillKey) == nil, "Health never answered")
        await store.setFailReads(false)
        await env.backfillMeasurementsOnce() // the next launch or foreground
        #expect(env.defaults.string(forKey: AppEnvironment.measuredBackfillKey) == "local")
        #expect(try saved(env)?.recordedBy == .watch)
    }

    @Test func aBackfillWithNoWorkoutsIsDone() async throws {
        let env = try await MeasuredFixture.environment(FakeHealthStore(), saved: false)
        await env.backfillMeasurementsOnce()
        #expect(env.defaults.string(forKey: AppEnvironment.measuredBackfillKey) == "local")
    }

    @Test func anAccountChangeDuringTheBackfillMarksNoAccount() async throws {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store)
        await store.setGate(true) // holds the read open
        let backfill = Task { await env.backfillMeasurementsOnce() }
        try await waitUntil { await store.parkedCount == 1 }
        env.syncStore.ownerUserId = UUID(uuidString: "00000000-0000-4000-8000-0000000000c1")! // signed in meanwhile
        await store.setGate(false)
        await backfill.value
        #expect(env.defaults.string(forKey: AppEnvironment.measuredBackfillKey) == nil,
                "neither the old account nor the new one is marked")
    }

    // MARK: Sign-out and account switch

    @Test func aSignOutForgetsTheSessionsReads() async throws {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store)
        _ = await env.measuredSummary(for: workout)
        env.measuredMemo.awaitingFinish.insert(UUID())
        env.measuredMemo.attachedWorkouts = [id]
        #expect(env.measuredMemo.lastSummary(for: id) != nil)
        env.sync.onLocalDataReset() // what a sign-out's or an account switch's wipe calls
        #expect(env.measuredMemo.lastSummary(for: id) == nil)
        #expect(env.measuredMemo.awaitingFinish.isEmpty && env.measuredMemo.attachedWorkouts == nil)
    }

    @Test func erasingAllDataForgetsTheSessionsReads() async throws {
        let env = try await MeasuredFixture.environment(FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()]))
        _ = await env.measuredSummary(for: workout)
        try env.eraseAllLocalData()
        #expect(env.measuredMemo.lastSummary(for: id) == nil)
    }

    @Test func aReadRunningWhenTheAccountChangesIsDropped() async throws {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store)
        let workout = self.workout
        await store.setGate(true) // holds the detail's read open
        let read = Task { await env.measuredSummary(for: workout) }
        try await waitUntil { await store.parkedCount == 1 }
        env.sync.onLocalDataReset()
        await store.setGate(false)
        _ = await read.value
        #expect(env.measuredMemo.lastSummary(for: id) == nil, "the old account's read isn't kept")
    }

    @Test func aResetMemoRefusesReadsStartedBeforeIt() {
        var memo = MeasuredMemo()
        let key = MeasuredMemo.Key(dataRevision: 0, healthOn: true, readsOutsideWorkouts: true)
        let summary = MeasuredSummary(source: .estimate, workoutTime: 3_500, activeKcal: nil, totalKcal: nil,
                                      estimatedKcal: nil, avgHr: 128, maxHr: 136, heartRate: [], postWorkout: [],
                                      lastPostHr: nil, postHr: nil, effort: nil)
        let before = memo.ticket(for: id)
        memo.backfilling = true
        memo.reset()
        let keptOld = memo.remember(summary, for: id, key: key, ticket: before)
        let keptNew = memo.remember(summary, for: id, key: key, ticket: memo.ticket(for: id))
        #expect(!keptOld && keptNew, "a read started before the reset is refused")
        #expect(memo.backfilling, "the running 90-day read clears it itself when it ends")
    }

    // MARK: Back to the foreground

    @Test func theForegroundRedrawsAnOpenDetailOnce() async throws {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store)
        env.defaults.set("local", forKey: AppEnvironment.measuredBackfillKey) // the 90-day read ran before
        _ = await env.measuredSummary(for: workout)
        let rated = Effort(score: 8, estimated: false)
        await store.setWorkoutMeasurements(MeasuredFixture.watchCopy(effort: rated), for: id) // rated in Fitness
        let revision = env.measuredRevision
        await env.syncHealth() // back to the foreground
        #expect(env.measuredRevision == revision + 1, "an open detail loads again")
        #expect(await env.measuredSummary(for: workout).effort == rated)
        #expect(await env.measuredSummary(for: workout).effort == rated)
        #expect(env.measuredRevision == revision + 1, "its read and save redraw nothing more")
        #expect(try saved(env)?.effort == 8)
    }
}
