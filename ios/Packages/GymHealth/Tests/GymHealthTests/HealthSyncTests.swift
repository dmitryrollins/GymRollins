import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymHealth

@MainActor
final class HealthFixture {
    let container: ModelContainer
    let defaults: UserDefaults
    let suite = "health-\(UUID())"
    var now = Date(timeIntervalSince1970: 1_790_000_000) // Mon 21 Sep 2026, 13:33 UTC
    var store: FakeHealthStore
    var bodyChanges = 0

    init(store: FakeHealthStore = FakeHealthStore()) throws {
        container = try GymStore.container(inMemory: true)
        defaults = UserDefaults(suiteName: suite)!
        self.store = store
    }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    var workouts: WorkoutRepository { WorkoutRepository(context: container.mainContext, now: { [unowned self] in now }) }
    var body: BodyRepository { BodyRepository(context: container.mainContext, now: { [unowned self] in now }) }

    func makeSync() -> HealthSync {
        HealthSync(store: store, workouts: workouts, body: body, defaults: defaults,
                   estimate: { workout in
                       CalorieEstimator.estimate(workout: workout, exercise: { _ in nil }, bodyWeightKg: 80,
                                                 table: HealthFixture.table)
                   },
                   now: { [unowned self] in now }, onBodyChanged: { [unowned self] in bodyChanges += 1 })
    }

    static let table = METTable(source: METSource(title: "t", citation: "c", url: "u", retrieved: "r", terms: []),
                                activities: CalorieActivity.allCodes.map {
                                    METActivity(code: $0, met: 5, description: "d", heading: "h")
                                })

    /// A finished app workout: 60 min, 10 weighted sets.
    @discardableResult
    func finishWorkout(name: String = "Push", startOffset: TimeInterval = 0, source: WorkoutSource = .app) throws
        -> Workout {
        let start = now.addingTimeInterval(startOffset)
        let workout = Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: name,
                              entries: [WorkoutEntry(exerciseId: "bench", sets: (0..<10).map { _ in
                                  WorkoutSet(weightKg: 60, reps: 8, done: true)
                              })], source: source)
        try workouts.save(workout)
        return workout
    }

    func advance(_ seconds: TimeInterval = 7_200) { now = now.addingTimeInterval(seconds) }

    /// Sign-out / account switch: every local row goes (no tombstones).
    func wipeLocalData() throws {
        try SyncStore(context: container.mainContext, defaults: defaults, now: { [unowned self] in now }).resetAll()
    }
}

@MainActor
@Suite struct HealthSyncExportTests {
    @Test func enableRequestsAuthorizationAndPersists() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        #expect(!sync.isEnabled)
        #expect(await sync.enable())
        #expect(sync.isEnabled)
        #expect(await fx.store.authorizationRequests == 1)
        #expect(sync.permissions.summary == .allowed)
        #expect(fx.makeSync().isEnabled) // survives relaunch
    }

    @Test func finishedWorkoutIsExportedOnceWithItsEstimate() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        #expect(sync.exportStatus(for: workout) == .pending)
        await sync.exportChanges()
        await sync.exportChanges()
        let saved = await fx.store.workouts
        #expect(saved.count == 1)
        #expect(await fx.store.saveCount == 1)
        #expect(saved.first?.externalId == workout.id)
        #expect(saved.first?.name == "Push")
        #expect(saved.first?.activity == .strength)
        #expect(saved.first?.kcal == 320) // active: (5 − 1) MET × 80 kg × 1 h
        #expect(sync.exportStatus(for: workout) == .saved)
    }

    @Test func workoutsBeforeEnablingOrImportedAreNotExported() async throws {
        let fx = try HealthFixture()
        let before = try fx.finishWorkout(name: "Before", startOffset: -86_400)
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let imported = try fx.finishWorkout(name: "Imported", source: .import)
        await sync.exportChanges()
        #expect(await fx.store.workouts.isEmpty)
        #expect(sync.exportStatus(for: before) == .notEligible)
        #expect(sync.exportStatus(for: imported) == .notEligible)
    }

    @Test func editingAWorkoutReplacesTheHealthCopy() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        await sync.exportChanges()
        try fx.workouts.save(Workout(id: workout.id, startedAt: workout.startedAt,
                                     endedAt: workout.startedAt.addingTimeInterval(1_800), name: "Push (edited)",
                                     entries: workout.entries))
        await sync.exportChanges()
        let saved = await fx.store.workouts
        #expect(saved.map(\.name) == ["Push (edited)"])
        #expect(saved.first?.kcal == 160)
    }

    @Test func deletingAWorkoutDeletesTheHealthCopy() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        await sync.exportChanges()
        try fx.workouts.delete(workout.id)
        await sync.exportChanges()
        #expect(await fx.store.workouts.isEmpty)
        #expect(sync.state.workouts.isEmpty)
    }

    @Test func exportIsIdempotentWhenTheLedgerIsLost() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        try fx.finishWorkout()
        await sync.exportChanges()
        var state = HealthSyncState.load(from: fx.defaults)
        state.workouts = [:]
        try state.save(to: fx.defaults)
        await fx.makeSync().exportChanges() // e.g. after a restore: re-saves, never duplicates
        #expect(await fx.store.workouts.count == 1)
    }

    @Test func failedSavesAreReportedAndRetried() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        await fx.store.setFailSaves(true)
        await sync.exportChanges()
        #expect(sync.exportStatus(for: workout) == .failed)
        await fx.store.setFailSaves(false)
        await sync.exportChanges()
        #expect(sync.exportStatus(for: workout) == .saved)
        #expect(await fx.store.workouts.count == 1)
    }

    @Test func concurrentExportsNeverDuplicate() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        try fx.finishWorkout()
        async let first: Void = sync.exportChanges()
        async let second: Void = sync.exportChanges()
        _ = await (first, second)
        #expect(await fx.store.workouts.count == 1)
    }

    @Test func disabledSyncDoesNothing() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        sync.disable()
        fx.advance()
        let workout = try fx.finishWorkout()
        await sync.exportChanges()
        #expect(await fx.store.workouts.isEmpty)
        #expect(sync.exportStatus(for: workout) == .notEnabled)
    }

    @Test func weighInsAreExportedUpdatedAndDeleted() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        let entry = BodyweightEntry(date: fx.now, weightKg: 81.4, bodyFatPct: 15)
        try fx.body.add(entry)
        try fx.body.add(BodyweightEntry(date: fx.now.addingTimeInterval(-86_400 * 30), weightKg: 80)) // too old
        await sync.exportChanges()
        #expect(await fx.store.weighIns == [HealthWeighIn(externalId: entry.id, date: entry.date, weightKg: 81.4,
                                                          bodyFatPct: 15)])
        try fx.body.upsert(BodyweightEntry(id: entry.id, date: entry.date, weightKg: 81.6))
        await sync.exportChanges()
        #expect(await fx.store.weighIns.map(\.weightKg) == [81.6])
        try fx.body.delete(entry.id)
        await sync.exportChanges()
        #expect(await fx.store.weighIns.isEmpty)
    }

    @Test func weighInsFromHealthAreNeverExportedBack() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        try fx.body.add(BodyweightEntry(date: fx.now, weightKg: 81, source: .appleHealth))
        await sync.exportChanges()
        #expect(await fx.store.weighIns.isEmpty)
    }
}

@MainActor
@Suite struct HealthSyncPermissionTests {
    @Test func unavailableHealthCannotBeEnabled() async throws {
        let fx = try HealthFixture(store: FakeHealthStore(isAvailable: false))
        let sync = fx.makeSync()
        #expect(!sync.isAvailable)
        #expect(await !sync.enable())
        #expect(!sync.isEnabled)
        #expect(await fx.store.authorizationRequests == 0)
        #expect(sync.lastError != nil)
    }

    @Test func partialPermissionStillExportsWhatIsAllowed() async throws {
        let store = FakeHealthStore(grantOnRequest: [.workouts: .denied, .activeEnergy: .denied,
                                                     .bodyMass: .authorized, .bodyFat: .authorized])
        let fx = try HealthFixture(store: store)
        let sync = fx.makeSync()
        #expect(await sync.enable())
        #expect(sync.permissions.summary == .partial)
        fx.advance()
        let workout = try fx.finishWorkout()
        try fx.body.add(BodyweightEntry(date: fx.now, weightKg: 81))
        await sync.exportChanges()
        #expect(sync.exportStatus(for: workout) == .failed)
        #expect(await store.weighIns.count == 1)
    }

    @Test func permissionSummaries() {
        let all = { (p: HealthPermission) in HealthPermissions(write: Dictionary(uniqueKeysWithValues:
            HealthDataType.allCases.map { ($0, p) })) }
        #expect(all(.authorized).summary == .allowed)
        #expect(all(.denied).summary == .denied)
        #expect(all(.notDetermined).summary == .notDetermined)
        #expect(HealthPermissions(write: [.workouts: .authorized]).summary == .partial)
    }
}

@MainActor
@Suite struct HealthSyncResetTests {
    /// Signing out wipes the local copy: Health must keep the workouts, and a re-pulled workout is re-saved, not
    /// duplicated.
    @Test func forgettingLocalDataNeverDeletesFromHealth() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        await sync.exportChanges()
        sync.localDataWasReset()
        try fx.wipeLocalData()
        await sync.exportChanges()
        #expect(await fx.store.workouts.count == 1)
        #expect(sync.isEnabled)
        try fx.workouts.save(workout)
        await sync.exportChanges()
        #expect(await fx.store.workouts.count == 1)
    }

    /// Round 11: back in the same account, a workout that didn't come back (deleted elsewhere meanwhile) leaves Health.
    @Test func sameAccountRestoreReconcilesDeletions() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        sync.owner = { "A" }
        _ = await sync.enable()
        fx.advance()
        let kept = try fx.finishWorkout(name: "Kept")
        try fx.finishWorkout(name: "Gone", startOffset: 60)
        await sync.exportChanges()
        sync.localDataWasReset()
        try fx.wipeLocalData()
        try fx.workouts.save(kept) // the pull brings back only this one
        sync.localDataRestored(lastPull: fx.now.addingTimeInterval(1))
        await sync.exportChanges()
        #expect(await fx.store.workouts.map(\.name) == ["Kept"])
    }

    @Test func anotherAccountForgetsTheLedgerWithoutDeleting() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        var owner = "A"
        sync.owner = { owner }
        _ = await sync.enable()
        fx.advance()
        try fx.finishWorkout()
        await sync.exportChanges()
        sync.localDataWasReset()
        try fx.wipeLocalData()
        owner = "B"
        sync.localDataRestored(lastPull: fx.now.addingTimeInterval(1))
        await sync.exportChanges()
        #expect(await fx.store.workouts.count == 1)
        #expect(sync.state.workouts.isEmpty)
    }

    @Test func aLocalDeletionWhileAwaitingRestoreStillReachesHealth() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        await sync.exportChanges()
        sync.localDataWasReset()
        try fx.workouts.delete(workout.id) // a real deletion (tombstone), not a wipe
        await sync.exportChanges()
        #expect(await fx.store.workouts.isEmpty)
    }

    @Test func resetTurnsHealthOffAndForgetsEverything() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        sync.reset()
        #expect(!sync.isEnabled)
        #expect(sync.state == HealthSyncState())
        #expect(HealthSyncState.load(from: fx.defaults) == HealthSyncState())
    }
}
