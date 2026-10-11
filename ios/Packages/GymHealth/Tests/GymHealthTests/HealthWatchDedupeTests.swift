import Foundation
import GymCore
import GymWatchLink
import Testing
@testable import GymHealth

/// Plan 17: when the Apple Watch records the workout (heart rate, measured energy) it writes the Health workout and the
/// phone doesn't — exactly one Health workout either way.
@MainActor
@Suite struct HealthWatchDedupeTests {
    private func enabled() async throws -> (HealthFixture, HealthSync) {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        return (fx, sync)
    }

    @Test func aClaimedWorkoutIsLeftToTheWatch() async throws {
        let (fx, sync) = try await enabled()
        let workout = try fx.finishWorkout()
        sync.acceptWatchClaim(workout.id)
        #expect(sync.isClaimedByWatch(workout.id))
        await sync.exportChanges()
        #expect(await fx.store.workouts.isEmpty)
        #expect(sync.exportStatus(for: workout) == .pending)
    }

    @Test func aWorkoutTheWatchRecordedIsNeverExportedByThePhone() async throws {
        let (fx, sync) = try await enabled()
        let workout = try fx.finishWorkout()
        sync.acceptWatchClaim(workout.id)
        await sync.exportChanges()
        sync.markRecordedByWatch(workout.id)
        #expect(sync.exportStatus(for: workout) == .saved)
        #expect(!sync.isClaimedByWatch(workout.id))
        // Later runs, even long after, and edits on the phone leave the watch's copy alone.
        fx.advance(86_400)
        try fx.workouts.save(Workout(id: workout.id, startedAt: workout.startedAt, endedAt: workout.endedAt,
                                     name: "Push (edited)", entries: workout.entries))
        await sync.exportChanges()
        #expect(await fx.store.workouts.isEmpty)
        #expect(await fx.store.deletedWorkoutIds.isEmpty)
        #expect(fx.makeSync().exportStatus(for: workout) == .saved) // survives relaunch
    }

    @Test func thePhoneExportsWhenTheWatchNeverConfirms() async throws {
        let (fx, sync) = try await enabled()
        let workout = try fx.finishWorkout()
        sync.acceptWatchClaim(workout.id)
        let end = try #require(workout.endedAt)
        fx.now = end.addingTimeInterval(WatchHealthRules.phoneFallbackDelay - 60)
        await sync.exportChanges()
        #expect(await fx.store.workouts.isEmpty)
        fx.now = end.addingTimeInterval(WatchHealthRules.phoneFallbackDelay)
        await sync.exportChanges()
        #expect(await fx.store.workouts.map(\.externalId) == [workout.id])
        #expect(sync.exportStatus(for: workout) == .saved)
    }

    @Test func aLateConfirmationDoesNotReplaceThePhonesExport() async throws {
        let (fx, sync) = try await enabled()
        let workout = try fx.finishWorkout()
        await sync.exportChanges() // no claim: the phone exported it
        sync.markRecordedByWatch(workout.id)
        #expect(sync.state.workouts[workout.id.uuidString] != WatchHealthRules.recordedByWatch)
        #expect(await fx.store.workouts.count == 1)
    }

    @Test func aDroppedClaimLetsThePhoneExport() async throws {
        let (fx, sync) = try await enabled()
        let workout = try fx.finishWorkout()
        sync.acceptWatchClaim(workout.id)
        sync.dropWatchClaim(workout.id)
        await sync.exportChanges()
        #expect(await fx.store.workouts.count == 1)
    }

    @Test func turningHealthOffRevokesTheWatchsClaim() async throws {
        let (fx, sync) = try await enabled()
        let workout = try fx.finishWorkout()
        sync.acceptWatchClaim(workout.id)
        sync.disable()
        #expect(!sync.isClaimedByWatch(workout.id)) // the watch is told not to save it
    }

    @Test func deletingAWatchRecordedWorkoutForgetsIt() async throws {
        let (fx, sync) = try await enabled()
        let workout = try fx.finishWorkout()
        sync.acceptWatchClaim(workout.id)
        sync.markRecordedByWatch(workout.id)
        try fx.workouts.delete(workout.id)
        await sync.exportChanges()
        #expect(await fx.store.deletedWorkoutIds == [workout.id]) // best effort: Health may keep the watch's copy
        #expect(sync.state.workouts.isEmpty)
    }

    @Test func claimsSurviveARelaunchAndAnOlderStateDecodes() throws {
        let fx = try HealthFixture()
        let id = UUID()
        fx.makeSync().acceptWatchClaim(id)
        #expect(fx.makeSync().isClaimedByWatch(id))
        // A state saved before plan 17 (no watch claims) still loads.
        let old = Data((#"{"enabled":true,"workouts":{"a":"b"},"weighIns":{},"lastImportCount":0,"pendingBodyFat":[],"#
            + #""unmatchedDeletions":[],"awaitingRestore":false}"#).utf8)
        let state = try JSONDecoder().decode(HealthSyncState.self, from: old)
        #expect(state.workouts == ["a": "b"])
        #expect(state.watchClaims.isEmpty)
    }
}
