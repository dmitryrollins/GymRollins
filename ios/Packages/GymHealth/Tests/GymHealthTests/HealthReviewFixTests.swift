import Foundation
import GymCore
import GymData
import Testing
@testable import GymHealth

/// Codex review round 1 (plan 15).
@MainActor
@Suite struct HealthReviewFixTests {
    private let day: TimeInterval = 86_400

    /// Waits (bounded) until the fake store has an operation parked at its gate.
    private func waitUntilParked(_ store: FakeHealthStore) async {
        for _ in 0..<1_000 where await store.parkedCount == 0 { await Task.yield() }
    }

    // P1: a reset during a HealthKit await must not be undone by the finishing run.
    @Test func resetDuringExportDiscardsTheRunsLedgerWrites() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        await fx.store.setGate(true)
        async let run: Void = sync.exportChanges()
        await waitUntilParked(fx.store)
        sync.localDataWasReset()
        await fx.store.setGate(false)
        await run
        // Never recorded as a finished export (only the "may be partly written" marker from before the save).
        #expect(!HealthSync.isComplete(sync.state.workouts[workout.id.uuidString]))
    }

    @Test func resetDuringImportDoesNotRepopulateWeighIns() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(seed: [HealthBodySample(kind: .bodyMass, value: 81, date: fx.now)])
        let sync = fx.makeSync()
        await fx.store.setGate(true)
        async let enabled = sync.enable()
        await waitUntilParked(fx.store)
        sync.reset()
        await fx.store.setGate(false)
        _ = await enabled
        #expect(try fx.body.entries(since: nil).isEmpty)
        #expect(!sync.isEnabled)
    }

    // P2: optional measurements don't block the authorized main record.
    @Test func deniedBodyFatStillExportsTheWeight() async throws {
        let store = FakeHealthStore(grantOnRequest: [.workouts: .authorized, .activeEnergy: .denied,
                                                     .bodyMass: .authorized, .bodyFat: .denied])
        let fx = try HealthFixture(store: store)
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        try fx.body.add(BodyweightEntry(date: fx.now, weightKg: 81, bodyFatPct: 15))
        await sync.exportChanges()
        #expect(await store.weighIns.map(\.weightKg) == [81])
        #expect(await store.bodySamples().filter { $0.kind == .bodyFat }.isEmpty)
        #expect(sync.exportStatus(for: workout) == .saved)
        #expect(await store.workouts.first?.kcal == nil) // energy not allowed: saved without it
    }

    // P2: re-enabling keeps earlier exports reconcilable.
    @Test func workoutsExportedBeforeReEnablingStillUpdate() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        let entry = BodyweightEntry(date: fx.now, weightKg: 81)
        try fx.body.add(entry)
        await sync.exportChanges()
        sync.disable()
        fx.advance(10 * day)
        _ = await sync.enable()
        try fx.workouts.save(Workout(id: workout.id, startedAt: workout.startedAt, endedAt: workout.endedAt,
                                     name: "Renamed", entries: workout.entries))
        try fx.body.upsert(BodyweightEntry(id: entry.id, date: entry.date, weightKg: 81.5))
        await sync.exportChanges()
        #expect(await fx.store.workouts.map(\.name) == ["Renamed"])
        #expect(await fx.store.weighIns.map(\.weightKg) == [81.5])
    }

    // P2: pauses are carried to Health.
    @Test func pausedTimeIsExported() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let start = fx.now
        try fx.workouts.save(Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), pausedSeconds: 600,
                                     name: "Paused", entries: [WorkoutEntry(exerciseId: "x", sets: [
                                         WorkoutSet(weightKg: 50, reps: 5, done: true)])]))
        await sync.exportChanges()
        #expect(await fx.store.workouts.first?.pausedSeconds == 600)
    }

    // P2: body fat that changes on its own reloads screens and syncs.
    @Test func bodyFatOnlyUpdateNotifies() async throws {
        let fx = try HealthFixture()
        let t = fx.now.addingTimeInterval(-day)
        fx.store = FakeHealthStore(seed: [HealthBodySample(kind: .bodyMass, value: 81, date: t)])
        let sync = fx.makeSync()
        _ = await sync.enable()
        let before = fx.bodyChanges
        await fx.store.addExternal(HealthBodySample(kind: .bodyFat, value: 14.8, date: t))
        await sync.importBody()
        #expect(fx.bodyChanges == before + 1)
    }

    // P2: body fat that arrives before its weight is kept until the weight shows up.
    @Test func bodyFatBeforeItsWeightIsAttachedLater() async throws {
        let fx = try HealthFixture()
        let t = fx.now.addingTimeInterval(-day)
        fx.store = FakeHealthStore(seed: [HealthBodySample(kind: .bodyFat, value: 16.1, date: t)])
        let sync = fx.makeSync()
        _ = await sync.enable()
        await fx.store.addExternal(HealthBodySample(kind: .bodyMass, value: 81, date: t.addingTimeInterval(30)))
        await sync.importBody()
        #expect(try fx.body.entries(since: nil).first?.bodyFatPct == 16.1)
        #expect(sync.state.pendingBodyFat.isEmpty)
    }

    // P2: deleting the body fat sample in Health clears it but keeps the weight.
    @Test func deletedBodyFatIsCleared() async throws {
        let fx = try HealthFixture()
        let t = fx.now.addingTimeInterval(-day)
        let fat = HealthBodySample(kind: .bodyFat, value: 15, date: t)
        fx.store = FakeHealthStore(seed: [HealthBodySample(kind: .bodyMass, value: 81, date: t), fat])
        let sync = fx.makeSync()
        _ = await sync.enable()
        #expect(try fx.body.entries(since: nil).first?.bodyFatPct == 15)
        await fx.store.deleteExternal(fat.uuid)
        await sync.importBody()
        let entries = try fx.body.entries(since: nil)
        #expect(entries.map(\.weightKg) == [81])
        #expect(entries.first?.bodyFatPct == nil)
    }
}
