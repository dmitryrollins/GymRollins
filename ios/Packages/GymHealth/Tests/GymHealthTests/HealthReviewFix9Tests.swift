import Foundation
import GymCore
import GymData
import Testing
@testable import GymHealth

/// Codex review round 9 (plan 15).
@MainActor
@Suite struct HealthReviewFix9Tests {
    private let allAllowed = Dictionary(uniqueKeysWithValues: HealthDataType.allCases.map { ($0, HealthPermission.authorized) })

    private func waitUntilParked(_ store: FakeHealthStore) async {
        for _ in 0..<1_000 where await store.parkedCount == 0 { await Task.yield() }
    }

    @Test func aFailedFirstExportIsStillCleanedUpWhenTheWorkoutIsDeleted() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        await fx.store.setFailSaves(true)
        await sync.exportChanges()
        #expect(sync.exportStatus(for: workout) == .failed)
        #expect(sync.state.workouts[workout.id.uuidString] != nil) // tracked: a partial write may exist
        try fx.workouts.delete(workout.id)
        await sync.exportChanges()
        #expect(await fx.store.deletedWorkoutIds.filter { $0 == workout.id }.count >= 2)
        #expect(sync.state.workouts.isEmpty)
    }

    @Test func deletionsStopWhenHealthIsTurnedOffMidway() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let a = try fx.finishWorkout(name: "A")
        let b = try fx.finishWorkout(name: "B", startOffset: 60)
        await sync.exportChanges()
        try fx.workouts.delete(a.id)
        try fx.workouts.delete(b.id)
        await fx.store.setGate(true, deletesToo: true)
        async let run: Void = sync.exportChanges()
        await waitUntilParked(fx.store)
        sync.disable()
        await fx.store.setGate(false)
        await run
        #expect(await fx.store.workouts.count == 1)
    }

    @Test func aRestoredPermissionClearsTheStaleFailure() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        await sync.exportChanges()
        var revoked = allAllowed
        revoked[.activeEnergy] = .denied
        await fx.store.setPermissions(revoked)
        await sync.exportChanges()
        #expect(sync.exportStatus(for: workout) == .failed)
        await fx.store.setPermissions(allAllowed)
        await sync.exportChanges()
        #expect(sync.exportStatus(for: workout) == .saved)
    }
}

/// Codex review round 10.
@MainActor
@Suite struct HealthReviewFix10Tests {
    @Test func aHalfFinishedDeleteIsNotMistakenForAnIntactExport() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        await sync.exportChanges()
        try fx.workouts.save(Workout(id: workout.id, startedAt: workout.startedAt, endedAt: workout.endedAt,
                                     name: "Edited", entries: workout.entries))
        await fx.store.setFailOptionalDeletes(true) // the workout goes, deleting its energy throws
        await sync.exportChanges()
        #expect(await fx.store.workouts.isEmpty, "the delete half-finished")
        #expect(sync.exportStatus(for: workout) == .failed)
        try fx.workouts.save(workout) // edit reverted
        await fx.store.setFailOptionalDeletes(false)
        await sync.exportChanges()
        #expect(await fx.store.workouts.map(\.name) == ["Push"])
    }

    @Test func pendingBodyFatAttachesToAWeighInThatArrivedFromTheCloud() async throws {
        let fx = try HealthFixture()
        let t = fx.now.addingTimeInterval(-3_600)
        fx.store = FakeHealthStore(seed: [HealthBodySample(kind: .bodyFat, value: 15.8, date: t)])
        let sync = fx.makeSync()
        _ = await sync.enable()
        #expect(sync.state.pendingBodyFat.count == 1)
        try fx.body.add(BodyweightEntry(date: t, weightKg: 81, source: .appleHealth, healthSampleId: UUID()))
        await sync.importBody()
        #expect(try fx.body.entries(since: nil).first?.bodyFatPct == 15.8)
        #expect(sync.state.pendingBodyFat.isEmpty)
    }
}

/// Codex review round 12.
@MainActor
@Suite struct HealthReviewFix12Tests {
    @Test func restoreNeedsASuccessfulPullAfterTheWipe() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        try fx.finishWorkout()
        await sync.exportChanges()
        sync.localDataWasReset()
        try fx.wipeLocalData()
        sync.localDataRestored(lastPull: nil) // the first round failed
        sync.localDataRestored(lastPull: fx.now.addingTimeInterval(-60)) // a pull from before the wipe
        await sync.exportChanges()
        #expect(sync.state.awaitingRestore)
        #expect(await fx.store.workouts.count == 1)
    }

    @Test func adoptingLocalDataMovesTheLedgerToTheAccount() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        var owner = "local"
        sync.owner = { owner }
        _ = await sync.enable()
        owner = "A" // signed in; the account adopted the local rows (no wipe)
        await sync.exportChanges()
        #expect(sync.state.ledgerOwner == "A")
    }
}

/// Codex review round 13.
@MainActor
@Suite struct HealthReviewFix13Tests {
    @Test func aReplacedWeightKeepsItsBodyFat() async throws {
        let fx = try HealthFixture()
        let t = fx.now.addingTimeInterval(-3_600)
        let old = HealthBodySample(kind: .bodyMass, value: 81, date: t)
        fx.store = FakeHealthStore(seed: [old, HealthBodySample(kind: .bodyFat, value: 15.3, date: t)])
        let sync = fx.makeSync()
        _ = await sync.enable()
        await fx.store.deleteExternal(old.uuid)
        await fx.store.addExternal(HealthBodySample(kind: .bodyMass, value: 81.1, date: t))
        await sync.importBody()
        let entries = try fx.body.entries(since: nil)
        #expect(entries.map(\.weightKg) == [81.1])
        #expect(entries.first?.bodyFatPct == 15.3)
    }
}

/// Codex review round 17.
@MainActor
@Suite struct HealthReviewFix17Tests {
    @Test func oneDecimalWeightsAtTheToleranceAreDuplicates() async throws {
        let fx = try HealthFixture()
        try fx.body.add(BodyweightEntry(date: fx.now.addingTimeInterval(-7_200), weightKg: 81.1))
        fx.store = FakeHealthStore(seed: [HealthBodySample(kind: .bodyMass, value: 81.2, date: fx.now.addingTimeInterval(-3_600))])
        _ = await fx.makeSync().enable()
        #expect(try fx.body.entries(since: nil).count == 1)
    }
}

/// Codex review round 18.
@MainActor
@Suite struct HealthReviewFix18Tests {
    @Test func aHalfFinishedCleanupIsNotMistakenForAnIntactExport() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        await sync.exportChanges()
        try fx.workouts.delete(workout.id)
        await fx.store.setFailOptionalDeletes(true) // the workout goes, deleting its energy throws
        await sync.exportChanges()
        try fx.workouts.save(workout) // restored (e.g. a conflict resolved the other way)
        await fx.store.setFailOptionalDeletes(false)
        await sync.exportChanges()
        #expect(await fx.store.workouts.count == 1)
    }
}
