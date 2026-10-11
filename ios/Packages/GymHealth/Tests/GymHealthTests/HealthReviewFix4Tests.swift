import Foundation
import GymCore
import GymData
import Testing
@testable import GymHealth

/// Codex review round 4 (plan 15).
@MainActor
@Suite struct HealthReviewFix4Tests {
    private let day: TimeInterval = 86_400
    private let allAllowed = Dictionary(uniqueKeysWithValues: HealthDataType.allCases.map { ($0, HealthPermission.authorized) })

    private func waitUntilParked(_ store: FakeHealthStore) async {
        for _ in 0..<1_000 where await store.parkedCount == 0 { await Task.yield() }
    }

    /// An imported weigh-in is stamped with the sample's own date, so a newer cloud tombstone still wins.
    @Test func importedWeighInsAreStampedWithTheSampleDate() async throws {
        let fx = try HealthFixture()
        let t = fx.now.addingTimeInterval(-3 * day)
        let sample = HealthBodySample(kind: .bodyMass, value: 81, date: t)
        fx.store = FakeHealthStore(seed: [sample])
        let sync = fx.makeSync()
        _ = await sync.enable()
        let syncStore = SyncStore(context: fx.container.mainContext, defaults: fx.defaults, now: { fx.now })
        let row = try #require(try syncStore.dirtyBodyweight().first)
        #expect(row.clientUpdatedAt == t)
        let id = try #require(try fx.body.entry(healthSampleId: sample.uuid)).id
        let tombstone = BodyweightEntry(id: id, date: t, weightKg: 81, source: .appleHealth)
        try syncStore.applyRemote(bodyweight: [SyncRow(value: tombstone, clientUpdatedAt: t.addingTimeInterval(day),
                                                       deletedAt: t.addingTimeInterval(day))])
        #expect(try fx.body.entries(since: nil).isEmpty)
    }

    /// Round 5: the Health sample id travels with the weigh-in (synced), so another device's copy is recognised
    /// whatever its row id, and a Health deletion finds it whatever the sign-in state.
    @Test func samplesAlreadySyncedFromAnotherDeviceAreNotImportedAgain() async throws {
        let fx = try HealthFixture()
        let sample = HealthBodySample(kind: .bodyMass, value: 81, date: fx.now.addingTimeInterval(-day))
        try fx.body.add(BodyweightEntry(date: sample.date, weightKg: 81, source: .appleHealth,
                                        healthSampleId: sample.uuid)) // pulled from the cloud
        fx.store = FakeHealthStore(seed: [sample])
        _ = await fx.makeSync().enable()
        #expect(try fx.body.entries(since: nil).count == 1)
    }

    @Test func healthDeletionFindsASyncedWeighIn() async throws {
        let fx = try HealthFixture()
        let sample = HealthBodySample(kind: .bodyMass, value: 81, date: fx.now.addingTimeInterval(-day))
        fx.store = FakeHealthStore(seed: [sample])
        let sync = fx.makeSync()
        _ = await sync.enable()
        let fatId = UUID()
        let entry = try #require(try fx.body.entries(since: nil).first)
        try fx.body.upsert(BodyweightEntry(id: entry.id, date: entry.date, weightKg: 81, bodyFatPct: 15,
                                           source: .appleHealth, healthSampleId: sample.uuid,
                                           healthFatSampleId: fatId))
        sync.localDataWasReset() // e.g. signed out and back in: links live on the synced row, not in local state
        await fx.store.addExternal(HealthBodySample(uuid: fatId, kind: .bodyFat, value: 15, date: sample.date))
        await fx.store.deleteExternal(fatId)
        await sync.importBody()
        #expect(try fx.body.entries(since: nil).first?.bodyFatPct == nil)
        await fx.store.deleteExternal(sample.uuid)
        await sync.importBody()
        #expect(try fx.body.entries(since: nil).isEmpty)
    }

    @Test func importWaitsForTheFirstCloudPull() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(seed: [HealthBodySample(kind: .bodyMass, value: 81, date: fx.now)])
        let sync = fx.makeSync()
        var pulled = false
        sync.canImport = { pulled }
        _ = await sync.enable()
        #expect(try fx.body.entries(since: nil).isEmpty)
        #expect(sync.state.anchor == nil)
        pulled = true
        await sync.importBody()
        #expect(try fx.body.entries(since: nil).count == 1)
    }

    /// Round 5: body fat attached to a historical weigh-in keeps the sample's date as edit time.
    @Test func attachedBodyFatKeepsTheSampleEditTime() async throws {
        let fx = try HealthFixture()
        let t = fx.now.addingTimeInterval(-3 * day)
        fx.store = FakeHealthStore(seed: [HealthBodySample(kind: .bodyMass, value: 81, date: t),
                                          HealthBodySample(kind: .bodyFat, value: 15, date: t)])
        _ = await fx.makeSync().enable()
        let syncStore = SyncStore(context: fx.container.mainContext, defaults: fx.defaults, now: { fx.now })
        let edited = try #require(try syncStore.dirtyBodyweight().first?.clientUpdatedAt)
        #expect(edited >= t && edited.timeIntervalSince(t) < 0.01)
    }

    @Test func revokedBodyFatKeepsTheDeletionPending() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        let entry = BodyweightEntry(date: fx.now, weightKg: 81, bodyFatPct: 15)
        try fx.body.add(entry)
        await sync.exportChanges()
        var revoked = allAllowed
        revoked[.bodyFat] = .denied
        await fx.store.setPermissions(revoked)
        try fx.body.delete(entry.id)
        await sync.exportChanges()
        #expect(sync.state.weighIns[entry.id.uuidString] != nil)
        await fx.store.setPermissions(allAllowed)
        await sync.exportChanges()
        #expect(await fx.store.bodySamples().filter { $0.fromThisApp }.isEmpty)
        #expect(sync.state.weighIns.isEmpty)
    }

    @Test func resetWhileDeletingTheOldCopyDoesNotSaveTheNewOne() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        await sync.exportChanges()
        try fx.workouts.save(Workout(id: workout.id, startedAt: workout.startedAt, endedAt: workout.endedAt,
                                     name: "Edited", entries: workout.entries))
        await fx.store.setGate(true, deletesToo: true)
        async let run: Void = sync.exportChanges()
        await waitUntilParked(fx.store)
        sync.localDataWasReset()
        await fx.store.setGate(false)
        await run
        #expect(await fx.store.saveCount == 1)
    }

    @Test func failedExportsAreRetriedAfterReEnabling() async throws {
        var grant = allAllowed
        grant[.workouts] = .denied
        let store = FakeHealthStore(grantOnRequest: grant)
        let fx = try HealthFixture(store: store)
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        await sync.exportChanges()
        #expect(sync.exportStatus(for: workout) == .failed)
        sync.disable()
        fx.advance(day)
        await store.setPermissions(allAllowed)
        _ = await sync.enable()
        #expect(await store.workouts.count == 1)
    }

    @Test func aSuccessfulImportClearsTheImportError() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        await fx.store.setFailReads(true)
        await sync.importBody()
        #expect(sync.lastError != nil)
        await fx.store.setFailReads(false)
        await sync.importBody()
        #expect(sync.lastError == nil)
    }
}

/// Codex round 7: a Health deletion that arrives while its weigh-in isn't on this iPhone (signed out, local data
/// wiped) is applied once the weigh-in comes back from the cloud.
@MainActor
@Suite struct HealthUnmatchedDeletionTests {
    @Test func deletionWaitsForTheRowToReturn() async throws {
        let fx = try HealthFixture()
        let sample = HealthBodySample(kind: .bodyMass, value: 81, date: fx.now.addingTimeInterval(-86_400))
        fx.store = FakeHealthStore(seed: [sample])
        let sync = fx.makeSync()
        _ = await sync.enable()
        let entry = try #require(try fx.body.entries(since: nil).first)
        try fx.body.delete(entry.id) // stands in for the local wipe
        sync.localDataWasReset()
        await fx.store.deleteExternal(sample.uuid)
        await sync.importBody()
        #expect(sync.state.unmatchedDeletions == [sample.uuid])
        // Signed back in: the cloud row returns (a fresh row, as a pull would insert it).
        try fx.body.add(BodyweightEntry(date: sample.date, weightKg: 81, source: .appleHealth,
                                        healthSampleId: sample.uuid))
        await sync.importBody()
        #expect(try fx.body.entries(since: nil).isEmpty)
        #expect(sync.state.unmatchedDeletions.isEmpty)
    }
}
