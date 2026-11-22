import Foundation
import GymCore
import GymData
import GymHealth
import Testing
@testable import GymRollins

/// Plan 40 in the app (spec §5.3–5.6): a workout's summary from Health, the snapshot saved when its numbers change,
/// and effort rated in GymRollins, which always stays in the app and goes to Health when Health takes it.
@MainActor
@Suite struct MeasuredEnvironmentTests {
    private let id = MeasuredFixture.workoutId
    private let workout = MeasuredFixture.workout()

    @Test func theWatchsCopyIsWhatTheDetailShowsAndItIsSaved() async throws {
        let env = try await MeasuredFixture.environment(FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()]))
        let summary = await env.measuredSummary(for: workout)
        #expect(summary.source == .watch)
        #expect(summary.workoutTime == 3_500)
        #expect(summary.activeKcal == 412 && summary.totalKcal == 489)
        #expect(summary.avgHr == 128 && summary.maxHr == 136 && summary.lastPostHr == 124)
        let saved = try #require(try env.measurements.snapshot(for: id))
        #expect(saved.recordedBy == .watch && saved.durationS == 3_500)
        #expect(saved.activeKcal == 412 && saved.totalKcal == 489 && saved.avgHr == 128 && saved.maxHr == 136)
        #expect(saved.effort == nil)
    }

    @Test func beforeHealthAnswersTheAppsOwnValuesShow() async throws {
        let env = try await MeasuredFixture.environment(FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()]))
        #expect(env.immediateMeasuredSummary(for: workout).source == .estimate)
        _ = await env.measuredSummary(for: workout)
        #expect(env.immediateMeasuredSummary(for: workout).source == .watch, "this session's read, at once")
    }

    @Test func withHealthOffItIsTheEstimateAndARatingStaysInTheApp() async throws {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store, healthOn: false)
        let summary = await env.measuredSummary(for: workout)
        #expect(summary.source == .estimate)
        #expect(summary.estimatedKcal == env.calories.estimate(workout)?.kcal)
        #expect(summary.heartRate.isEmpty && summary.avgHr == nil)
        #expect(await env.rateEffort(6, for: workout) == .saved)
        #expect(await env.measuredSummary(for: workout).effort == Effort(score: 6, estimated: false))
        #expect(try env.measurements.snapshot(for: id)?.effort == 6)
        #expect(await store.ratedEfforts.isEmpty, "nothing is written to Health")
    }

    @Test func aRatingGoesToHealthAndAClearBringsTheEstimateBack() async throws {
        let estimate = Effort(score: 5, estimated: true)
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy(effort: estimate)])
        let env = try await MeasuredFixture.environment(store)
        #expect(await env.measuredSummary(for: workout).effort == estimate)
        #expect(await env.rateEffort(7, for: workout) == .saved)
        #expect(await store.ratedEfforts[id] == 7)
        #expect(await env.measuredSummary(for: workout).effort == Effort(score: 7, estimated: false))
        await env.clearEffort(for: workout)
        #expect(await store.ratedEfforts[id] == nil)
        #expect(await env.measuredSummary(for: workout).effort == estimate, "the Apple Watch's estimate again")
        let saved = try #require(try env.measurements.snapshot(for: id))
        #expect(saved.effort == 5 && saved.effortEstimated)
    }

    @Test func aRatingMadeInFitnessWinsAndIsAdopted() async throws {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy(effort: Effort(score: 8, estimated: false))])
        let env = try await MeasuredFixture.environment(store, healthOn: false)
        _ = await env.rateEffort(4, for: workout) // Health off: the app's own
        #expect(await env.health.enable())
        #expect(await env.measuredSummary(for: workout).effort == Effort(score: 8, estimated: false))
        #expect(try env.measurements.snapshot(for: id)?.effort == 8, "adopted, so the cloud has it too")
    }

    @Test func aFailedHealthWriteKeepsTheRatingAndSaysSo() async throws {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store)
        _ = await env.measuredSummary(for: workout)
        await store.setFailEffortWrites(true)
        #expect(await env.rateEffort(8, for: workout) == .savedInAppOnly)
        #expect(await env.measuredSummary(for: workout).effort == Effort(score: 8, estimated: false))
        #expect(try env.measurements.snapshot(for: id)?.effort == 8)
    }

    @Test func withoutACopyInHealthTheRatingIsTheAppsOnly() async throws {
        let env = try await MeasuredFixture.environment(FakeHealthStore())
        #expect(await env.rateEffort(5, for: workout) == .savedInAppOnly, "Health is on and allowed, but has no copy")
        #expect(try env.measurements.snapshot(for: id)?.effort == 5)
    }

    @Test func outOfRangeScoresAreIgnored() async throws {
        let env = try await MeasuredFixture.environment(FakeHealthStore(), healthOn: false)
        #expect(await env.rateEffort(11, for: workout) == .saved)
        #expect(try env.measurements.snapshot(for: id) == nil)
    }

    @Test func aReadIsRememberedUnderWhatItStartedWith() async throws {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store)
        let workout = self.workout
        await store.setGate(true) // holds the read open
        let read = Task { await env.measuredSummary(for: workout) }
        try await waitUntil { await store.parkedCount == 1 }
        env.bumpDataRevision() // a pull landed meanwhile
        await store.setGate(false)
        #expect(await read.value.source == .watch)
        #expect(env.immediateMeasuredSummary(for: workout).source == .estimate, "not kept as the new data's read")
    }

    @Test func aReadOvertakenByANewerOneKeepsAndSavesNothing() async throws {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store)
        let workout = self.workout
        await store.setGate(true) // holds the detail's read open
        let read = Task { await env.measuredSummary(for: workout) }
        try await waitUntil { await store.parkedCount == 1 }
        env.measuredMemo.forget(id) // what a hook's, a rating's or a clear's re-read does first
        await store.setGate(false)
        #expect(await read.value.source == .watch, "the screen still gets an answer")
        #expect(try env.measurements.snapshot(for: id) == nil, "the newer read saves its own")
        #expect(env.immediateMeasuredSummary(for: workout).source == .estimate)
    }

    @Test func theMemoKeepsOnlyTheNewestRead() {
        var memo = MeasuredMemo()
        let key = MeasuredMemo.Key(dataRevision: 0, healthOn: true, readsOutsideWorkouts: true)
        let older = Self.summary(avgHr: 120)
        let newer = Self.summary(avgHr: 128)
        let stale = memo.ticket(for: id)
        memo.forget(id) // a hook's re-read starts
        let keptNewer = memo.remember(newer, for: id, key: key, ticket: memo.ticket(for: id))
        let keptOlder = memo.remember(older, for: id, key: key, ticket: stale)
        #expect(keptNewer && !keptOlder, "the older read finished last")
        #expect(memo.summary(for: id, key: key) == newer)
        let other = UUID()
        let otherTicket = memo.ticket(for: other)
        memo.forget(id)
        let keptOther = memo.remember(older, for: other, key: key, ticket: otherTicket)
        #expect(keptOther, "another workout's forget leaves it")
        let beforeForeground = memo.ticket(for: id)
        memo.backfilling = true
        memo.forgetAll() // back to the foreground: read again next time
        #expect(memo.summary(for: id, key: key) == nil)
        let keptAcrossForeground = memo.remember(newer, for: id, key: key, ticket: beforeForeground)
        #expect(keptAcrossForeground, "a read already running is current enough")
        #expect(memo.backfilling, "a running 90-day read stays marked")
    }

    @Test func withHealthOffTheSavedNumbersStay() async throws {
        let env = try await MeasuredFixture.environment(FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()]))
        _ = await env.measuredSummary(for: workout)
        let before = try #require(try env.measurements.snapshot(for: id))
        env.health.disable()
        #expect(await env.measuredSummary(for: workout).source == .estimate, "the app's values show")
        #expect(try env.measurements.snapshot(for: id) == before, "the cloud keeps what was measured")
    }

    @Test func aFailedReadKeepsTheSavedNumbers() async throws {
        let store = FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()])
        let env = try await MeasuredFixture.environment(store)
        _ = await env.measuredSummary(for: workout)
        let before = try #require(try env.measurements.snapshot(for: id))
        await store.setFailReads(true)
        await env.refreshMeasurements(for: [id])
        #expect(env.immediateMeasuredSummary(for: workout).source == .estimate, "the app's values show")
        #expect(try env.measurements.snapshot(for: id) == before)
    }

    private static func summary(avgHr: Int) -> MeasuredSummary {
        MeasuredSummary(source: .estimate, workoutTime: 3_500, activeKcal: nil, totalKcal: nil, estimatedKcal: nil,
                        avgHr: avgHr, maxHr: avgHr, heartRate: [], postWorkout: [], lastPostHr: nil, postHr: nil,
                        effort: nil)
    }

    @Test func aRefreshReadsHealthAgainAndRedrawsAnOpenDetail() async throws {
        let env = try await MeasuredFixture.environment(FakeHealthStore(measurements: [id: MeasuredFixture.watchCopy()]))
        #expect(try env.measurements.snapshot(for: id) == nil, "nothing read yet")
        let revision = env.measuredRevision
        await env.refreshMeasurements(for: [id, UUID()]) // an id with no workout is skipped
        #expect(try env.measurements.snapshot(for: id)?.recordedBy == .watch)
        #expect(env.measuredRevision > revision)
    }
}
