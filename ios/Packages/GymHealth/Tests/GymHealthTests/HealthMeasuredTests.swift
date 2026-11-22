import Foundation
import GymCore
import GymData
import Testing
@testable import GymHealth

/// Plan 40, spec §5: a GymRollins workout's Health data through `HealthSync`. Reads answer nil rather than throw,
/// effort writes say whether Health took them, and the Effort card's Allow pill shows until the effort types were
/// asked.
@MainActor
@Suite struct HealthMeasuredTests {
    /// A dozen readings, 110–162 BPM, mean 128, inside a workout that started at `start`.
    private func readings(from start: Date) -> [HeartRateReading] {
        [110.0, 118, 122, 126, 130, 162, 135, 128, 124, 120, 131, 130].enumerated().map { index, bpm in
            HeartRateReading(date: start.addingTimeInterval(60 + Double(index) * 290), bpm: bpm)
        }
    }

    private func copy(_ recordedBy: WorkoutMeasurements.Copy, of workout: Workout,
                      effort: Effort? = nil) -> WorkoutMeasurements {
        WorkoutMeasurements(recordedBy: recordedBy, duration: 3_500, activeKcal: 412, totalKcal: 489,
                            heartRate: readings(from: workout.startedAt), postWorkout: [], effort: effort)
    }

    /// Health on, and a finished workout whose Health copy is `recordedBy` (none when nil).
    private func enabled(_ recordedBy: WorkoutMeasurements.Copy? = .watch, effort: Effort? = nil) async throws
        -> (HealthFixture, HealthSync, Workout) {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        let workout = try fx.finishWorkout(startOffset: -7_200)
        if let recordedBy {
            await fx.store.setWorkoutMeasurements(copy(recordedBy, of: workout, effort: effort), for: workout.id)
        }
        return (fx, sync, workout)
    }

    private func shown(_ read: WorkoutMeasurements?, for workout: Workout) -> MeasuredSummary {
        WorkoutMeasuredRules.summary(start: workout.startedAt, end: workout.endedAt ?? workout.startedAt,
                                     appDuration: 3_600, measurements: read, attached: nil, estimateKcal: 320,
                                     appEffort: nil)
    }

    @Test func aWatchCopyIsMeasured() async throws {
        let (_, sync, workout) = try await enabled(.watch)
        let read = try #require(await sync.measurements(for: workout))
        #expect(read.recordedBy == .watch && read.duration == 3_500)
        #expect(read.activeKcal == 412 && read.totalKcal == 489)
        let summary = shown(read, for: workout)
        #expect(summary.source == .watch && summary.activeKcal == 412 && summary.avgHr == 128)
    }

    @Test func aPhoneCopyIsNeverMeasured() async throws {
        let (_, sync, workout) = try await enabled(.phone)
        let read = try #require(await sync.measurements(for: workout))
        #expect(read.recordedBy == .phone)
        #expect(read.duration == nil && read.activeKcal == nil && read.totalKcal == nil)
        let summary = shown(read, for: workout)
        #expect(summary.source == .estimate && summary.estimatedKcal == 320 && summary.activeKcal == nil)
        #expect(summary.avgHr == 128 && summary.maxHr == 162, "the readings count whatever wrote the copy")
    }

    @Test func healthOffUnavailableOrRunningReadsNothing() async throws {
        let fx = try HealthFixture()
        let workout = try fx.finishWorkout()
        await fx.store.setWorkoutMeasurements(copy(.watch, of: workout), for: workout.id)
        #expect(await fx.makeSync().measurements(for: workout) == nil, "Health off")

        let noHealth = try HealthFixture(store: FakeHealthStore(isAvailable: false))
        let unavailable = noHealth.makeSync()
        _ = await unavailable.enable()
        #expect(await unavailable.measurements(for: workout) == nil)

        let (_, sync, _) = try await enabled()
        let running = Workout(startedAt: fx.now, name: "Push")
        #expect(await sync.measurements(for: running) == nil)
    }

    @Test func nothingIsReadBeforeTheActivityTypesWereAsked() async throws {
        let fx = try HealthFixture()
        try HealthSyncState.saveEnabledBeforeActivity(to: fx.defaults, at: fx.now)
        let workout = try fx.finishWorkout(startOffset: 3_600)
        await fx.store.setWorkoutMeasurements(copy(.watch, of: workout), for: workout.id)
        let sync = fx.makeSync()
        #expect(sync.isEnabled)
        #expect(await sync.measurements(for: workout) == nil)
        #expect(!sync.effortNeedsAsking, "the activity card asks first")
    }

    @Test func aFailedReadAnswersNilAndTheNextOneRecovers() async throws {
        let (fx, sync, workout) = try await enabled()
        await fx.store.setFailReads(true)
        #expect(await sync.measurements(for: workout) == nil)
        await fx.store.setFailReads(false)
        #expect(await sync.measurements(for: workout)?.recordedBy == .watch)
    }

    @Test func aResetDuringTheReadAnswersNil() async throws {
        let (fx, sync, workout) = try await enabled()
        await fx.store.setGate(true)
        let read = Task { await sync.measurements(for: workout) }
        while await fx.store.parkedCount == 0 { await Task.yield() }
        sync.reset()
        await fx.store.setGate(false)
        #expect(await read.value == nil)
    }

    @Test func aRatingIsSavedToHealthAndReadBack() async throws {
        let (fx, sync, workout) = try await enabled()
        #expect(await sync.rateEffort(6, for: workout))
        #expect(await fx.store.ratedEfforts == [workout.id: 6])
        #expect(await sync.measurements(for: workout)?.effort == Effort(score: 6, estimated: false))
    }

    @Test func aNewRatingReplacesTheOldAndClearingBringsBackTheWatchsEstimate() async throws {
        let estimate = try #require(Effort(score: 5, estimated: true))
        let (fx, sync, workout) = try await enabled(effort: estimate)
        #expect(await sync.rateEffort(6, for: workout))
        #expect(await sync.rateEffort(8, for: workout))
        #expect(await fx.store.ratedEfforts == [workout.id: 8])
        #expect(await sync.clearEffort(for: workout))
        #expect(await fx.store.ratedEfforts.isEmpty)
        #expect(await sync.measurements(for: workout)?.effort == estimate)
    }

    @Test func withoutAHealthCopyNothingIsWritten() async throws {
        let (fx, sync, workout) = try await enabled(nil)
        #expect(!(await sync.rateEffort(6, for: workout)))
        #expect(await fx.store.ratedEfforts.isEmpty)
    }

    @Test func aFailedWriteOrHealthOffSaysFalse() async throws {
        let (fx, sync, workout) = try await enabled()
        await fx.store.setFailEffortWrites(true)
        #expect(!(await sync.rateEffort(6, for: workout)))
        #expect(!(await sync.clearEffort(for: workout)))
        await fx.store.setFailEffortWrites(false)
        #expect(!(await sync.rateEffort(0, for: workout)), "not a score")
        sync.disable()
        #expect(!(await sync.rateEffort(6, for: workout)))
        #expect(await fx.store.ratedEfforts.isEmpty)
    }

    @Test func turningHealthOnAsksForTheEffortTypesToo() async throws {
        let (fx, sync, workout) = try await enabled()
        _ = await sync.measurements(for: workout)
        #expect(await fx.store.effortAsked)
        #expect(!sync.effortNeedsAsking)
    }

    @Test func healthAllowedBeforePlan40ShowsTheAllowPillUntilAsked() async throws {
        let (fx, sync, workout) = try await enabled()
        await fx.store.setEffortAsked(false) // build 4 asked without the effort types
        #expect(!sync.effortNeedsAsking, "unknown until checked")
        _ = await sync.measurements(for: workout)
        #expect(sync.effortNeedsAsking)
        #expect(!(await sync.rateEffort(6, for: workout)), "not allowed yet: the rating stays in the app")
        #expect(await fx.store.ratedEfforts.isEmpty)

        await sync.askForEffort()
        #expect(!sync.effortNeedsAsking)
        #expect(await fx.store.authorizationRequests == 2)
        #expect(await sync.rateEffort(6, for: workout))
    }
}
