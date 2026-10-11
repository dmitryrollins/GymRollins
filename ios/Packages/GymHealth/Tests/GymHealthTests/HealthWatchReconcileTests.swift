import Foundation
import GymCore
import GymWatchLink
import Testing
@testable import GymHealth

/// Codex review of plan 17: the watch's Health workout is never replaced by the phone's estimate. Before its fallback
/// export the phone looks in Health for the watch's copy (watch samples sync to the phone's Health store); a late
/// confirmation is still taken; and when both copies exist, the phone's own one goes and the measured one stays.
@MainActor
@Suite struct HealthWatchReconcileTests {
    private func enabled() async throws -> (HealthFixture, HealthSync) {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        return (fx, sync)
    }

    /// The watch's measured copy, as it shows up in the phone's Health store.
    private func watchCopy(of workout: Workout) throws -> HealthWorkout {
        HealthWorkout(externalId: workout.id, name: workout.name, start: workout.startedAt,
                      end: try #require(workout.endedAt), kcal: 312, activity: .strength)
    }

    private func pastFallback(_ fx: HealthFixture, _ workout: Workout) throws {
        fx.now = try #require(workout.endedAt).addingTimeInterval(WatchHealthRules.phoneFallbackDelay + 60)
    }

    // MARK: Late confirmation

    @Test func aConfirmationWithinTheWindowIsTaken() async throws {
        let (fx, sync) = try await enabled()
        let workout = try fx.finishWorkout()
        sync.acceptWatchClaim(workout.id)
        fx.now = try #require(workout.endedAt).addingTimeInterval(WatchHealthRules.phoneFallbackDelay - 60)
        sync.markRecordedByWatch(workout.id)
        await sync.exportChanges()
        #expect(sync.state.workouts[workout.id.uuidString] == WatchHealthRules.recordedByWatch)
        #expect(await fx.store.saveCount == 0)
    }

    @Test func aConfirmationAfterTheWindowIsTakenWhenThePhoneHasntExported() async throws {
        let (fx, sync) = try await enabled()
        let workout = try fx.finishWorkout()
        sync.acceptWatchClaim(workout.id)
        try pastFallback(fx, workout) // no export run happened meanwhile (app in the background)
        sync.markRecordedByWatch(workout.id)
        sync.markRecordedByWatch(workout.id) // delivered twice: idempotent
        await sync.exportChanges()
        #expect(sync.state.workouts[workout.id.uuidString] == WatchHealthRules.recordedByWatch)
        #expect(await fx.store.saveCount == 0)
        #expect(sync.exportStatus(for: workout) == .saved)
    }

    @Test func aConfirmationArrivingWhileThePhonesFirstExportIsInFlightStopsIt() async throws {
        let (fx, sync) = try await enabled()
        let workout = try fx.finishWorkout()
        sync.acceptWatchClaim(workout.id)
        try pastFallback(fx, workout)
        await fx.store.setGate(true, deletesToo: true)
        let run = Task { await sync.exportChanges() }
        while await fx.store.parkedCount == 0 { await Task.yield() }
        sync.markRecordedByWatch(workout.id) // the queued confirmation lands mid-export
        await fx.store.setGate(false)
        await run.value
        #expect(await fx.store.saveCount == 0, "the phone's estimate must not replace the watch's workout")
        #expect(sync.state.workouts[workout.id.uuidString] == WatchHealthRules.recordedByWatch)
    }

    @Test func aConfirmationArrivingDuringThePhonesPreSaveDeleteKeepsTheWatchsCopy() async throws {
        let (fx, sync) = try await enabled()
        let workout = try fx.finishWorkout()
        sync.acceptWatchClaim(workout.id)
        try pastFallback(fx, workout)
        await fx.store.setGate(true, deletesToo: true, readsToo: false)
        let run = Task { await sync.exportChanges() } // the lookup finds nothing, then parks at the delete
        while await fx.store.parkedCount == 0 { await Task.yield() }
        await fx.store.addWatchWorkout(try watchCopy(of: workout)) // the watch's copy syncs over…
        sync.markRecordedByWatch(workout.id) // …and its confirmation lands
        await fx.store.setGate(false)
        await run.value
        #expect(await fx.store.watchWorkouts.map(\.externalId) == [workout.id], "the measured copy survives")
        #expect(await fx.store.saveCount == 0)
        #expect(sync.state.workouts[workout.id.uuidString] == WatchHealthRules.recordedByWatch)
    }

    // MARK: Watch copy already in Health

    @Test func theFallbackFindsTheWatchsCopyAndNeverExports() async throws {
        let (fx, sync) = try await enabled()
        let workout = try fx.finishWorkout()
        sync.acceptWatchClaim(workout.id)
        await fx.store.addWatchWorkout(try watchCopy(of: workout)) // saved in time; its confirmation never came
        try pastFallback(fx, workout)
        await sync.exportChanges()
        #expect(await fx.store.saveCount == 0)
        #expect(await fx.store.watchWorkouts.map(\.externalId) == [workout.id])
        #expect(sync.state.workouts[workout.id.uuidString] == WatchHealthRules.recordedByWatch)
        #expect(!sync.isClaimedByWatch(workout.id))
        #expect(sync.exportStatus(for: workout) == .saved)
        // A later confirmation is a no-op.
        sync.markRecordedByWatch(workout.id)
        await sync.exportChanges()
        #expect(await fx.store.deletedWorkoutIds.isEmpty)
    }

    @Test func withoutAWatchCopyTheFallbackExports() async throws {
        let (fx, sync) = try await enabled()
        let workout = try fx.finishWorkout()
        sync.acceptWatchClaim(workout.id)
        try pastFallback(fx, workout)
        await sync.exportChanges()
        #expect(await fx.store.workouts.map(\.externalId) == [workout.id])
    }

    @Test func aFailedLookupSkipsTheExportUntilTheNextRun() async throws {
        let (fx, sync) = try await enabled()
        let workout = try fx.finishWorkout()
        sync.acceptWatchClaim(workout.id)
        try pastFallback(fx, workout)
        await fx.store.setFailReads(true)
        await sync.exportChanges()
        #expect(await fx.store.saveCount == 0)
        #expect(sync.exportStatus(for: workout) == .failed)
        await fx.store.setFailReads(false)
        await sync.exportChanges()
        #expect(await fx.store.workouts.map(\.externalId) == [workout.id])
    }

    @Test func aFallbackExportIsNotLookedUpAgainOnEveryRun() async throws {
        let (fx, sync) = try await enabled()
        let workout = try fx.finishWorkout()
        sync.acceptWatchClaim(workout.id)
        try pastFallback(fx, workout)
        await sync.exportChanges() // looked, found nothing, exported
        let lookups = await fx.store.workoutLookups
        await fx.store.setFailReads(true)
        await sync.exportChanges()
        await sync.exportChanges()
        #expect(await fx.store.workoutLookups == lookups)
        #expect(sync.exportStatus(for: workout) == .saved)
    }

    @Test func unclaimedWorkoutsDontLookInHealth() async throws {
        let (fx, sync) = try await enabled()
        _ = try fx.finishWorkout()
        await sync.exportChanges()
        #expect(await fx.store.workoutLookups == 0)
    }

    // MARK: Phone exported, then the watch confirms

    @Test func whenBothCopiesExistThePhonesOwnGoesAndTheMeasuredOneStays() async throws {
        let (fx, sync) = try await enabled()
        let workout = try fx.finishWorkout()
        sync.acceptWatchClaim(workout.id)
        try pastFallback(fx, workout)
        await sync.exportChanges() // nothing from the watch yet: the phone exported its estimate
        #expect(await fx.store.workouts.count == 1)
        let deletesBefore = await fx.store.ownDeletedWorkoutIds.count
        await fx.store.addWatchWorkout(try watchCopy(of: workout)) // the watch's copy syncs over
        sync.markRecordedByWatch(workout.id) // …and its queued confirmation arrives
        await sync.exportChanges()
        #expect(await fx.store.workouts.isEmpty, "the phone's estimate is removed")
        #expect(await fx.store.watchWorkouts.map(\.externalId) == [workout.id], "the measured copy stays")
        #expect(await fx.store.ownDeletedWorkoutIds.dropFirst(deletesBefore) == [workout.id])
        #expect(sync.state.workouts[workout.id.uuidString] == WatchHealthRules.recordedByWatch)
        #expect(sync.exportStatus(for: workout) == .saved)
    }

    @Test func aConfirmationWithoutAVisibleWatchCopyKeepsThePhonesCopyAndGivesUpLater() async throws {
        let (fx, sync) = try await enabled()
        let workout = try fx.finishWorkout()
        sync.acceptWatchClaim(workout.id)
        try pastFallback(fx, workout)
        await sync.exportChanges()
        let deletesBefore = await fx.store.ownDeletedWorkoutIds.count
        sync.markRecordedByWatch(workout.id) // the watch's copy isn't in this Health store (or was replaced)
        await sync.exportChanges()
        #expect(await fx.store.workouts.count == 1, "never delete the only copy")
        #expect(await fx.store.ownDeletedWorkoutIds.count == deletesBefore)
        #expect(sync.state.watchAcks[workout.id.uuidString] != nil) // looked for again on later runs
        fx.advance(HealthSync.watchAckWindow + 60)
        await sync.exportChanges()
        #expect(sync.state.watchAcks.isEmpty)
        #expect(!sync.isClaimedByWatch(workout.id), "done looking: the claim goes too")
        let lookups = await fx.store.workoutLookups
        await sync.exportChanges()
        #expect(await fx.store.workoutLookups == lookups)
        #expect(await fx.store.workouts.count == 1)
        #expect(sync.exportStatus(for: workout) == .saved)
    }

    @Test func pendingConfirmationsSurviveARelaunchAndOlderStatesDecode() throws {
        let fx = try HealthFixture()
        let id = UUID()
        let sync = fx.makeSync()
        sync.update { $0.workouts[id.uuidString] = "fingerprint" }
        sync.markRecordedByWatch(id)
        #expect(fx.makeSync().state.watchAcks[id.uuidString] != nil)
        let old = Data((#"{"enabled":true,"workouts":{},"weighIns":{},"lastImportCount":0,"pendingBodyFat":[],"#
            + #""unmatchedDeletions":[],"awaitingRestore":false}"#).utf8)
        #expect(try JSONDecoder().decode(HealthSyncState.self, from: old).watchAcks.isEmpty)
    }
}
