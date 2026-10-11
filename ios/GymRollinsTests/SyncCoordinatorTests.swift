import Foundation
import GymCore
import GymData
import GymSync
import SwiftData
import Testing
@testable import GymRollins

/// Records sleeps and lets the test decide when each one finishes.
private actor ManualSleeper {
    private var waiters: [CheckedContinuation<Void, Error>] = []
    var count: Int { waiters.count }

    func sleep() async throws {
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func releaseAll() {
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor
@Suite struct SyncDebouncerTests {
    @Test func burstRunsTheActionOnceAfterTheLastCall() async throws {
        let sleeper = ManualSleeper()
        let debouncer = SyncDebouncer(delay: .seconds(2), sleep: { _ in try await sleeper.sleep() })
        var runs = 0
        for _ in 0..<3 { debouncer.schedule { runs += 1 } }
        try await waitUntil { await sleeper.count == 3 }
        await sleeper.releaseAll()
        try await waitUntil { !debouncer.isPending }
        #expect(runs == 1)
    }

    @Test func cancelDropsThePendingAction() async throws {
        let sleeper = ManualSleeper()
        let debouncer = SyncDebouncer(delay: .seconds(2), sleep: { _ in try await sleeper.sleep() })
        var runs = 0
        debouncer.schedule { runs += 1 }
        try await waitUntil { await sleeper.count == 1 }
        debouncer.cancel()
        await sleeper.releaseAll()
        await debouncer.lastScheduled?.value // the cancelled wait has finished
        #expect(runs == 0)
        #expect(!debouncer.isPending)
    }

    @Test func realDelayRunsOnce() async throws {
        let debouncer = SyncDebouncer(delay: .milliseconds(30))
        var runs = 0
        debouncer.schedule { runs += 1 }
        debouncer.schedule { runs += 1 }
        await debouncer.lastScheduled?.value // the first wait was cancelled by the second schedule
        #expect(runs == 1)
    }
}

@MainActor
@Suite struct SyncCoordinatorTests {
    let container: ModelContainer
    let defaults: UserDefaults
    let suite = "coordinator-\(UUID())"
    let now = ISO8601DateFormatter().date(from: "2026-09-26T09:00:00Z")!

    init() throws {
        container = try GymStore.container(inMemory: true)
        defaults = UserDefaults(suiteName: suite)!
    }

    private func coordinator() -> SyncCoordinator {
        let store = SyncStore(context: container.mainContext, defaults: defaults, now: Date.init)
        let fake = SeededConflictTransport()
        return SyncCoordinator(auth: nil, store: store, now: Date.init, makeTransport: { _ in fake })
    }

    private func saveWorkout() throws -> Workout {
        let workout = Workout(startedAt: now, endedAt: now.addingTimeInterval(1_800), name: "Push", entries: [
            WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: 60, reps: 8, done: true),
                                                    WorkoutSet(weightKg: 60, reps: 8, done: true)]),
        ])
        try WorkoutRepository(context: container.mainContext, now: Date.init).save(workout)
        return workout
    }

    @Test func disabledBackendNeverSyncs() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SyncStore(context: container.mainContext, defaults: defaults)
        let sync = SyncCoordinator(auth: nil, store: store, now: Date.init, makeTransport: { _ in nil })
        await sync.start()
        #expect(sync.engine == nil)
        #expect(sync.status == .idle)
        #expect(!sync.isAvailable)
        sync.setActive(false)
    }

    @Test func conflictThenKeepLocalClearsAndCountsPending() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = coordinator()
        let workout = try saveWorkout()
        var remoteChanges = 0
        sync.onRemoteChanges = { remoteChanges += 1 }

        await sync.start()
        sync.setActive(false)
        #expect(sync.status == .conflicts([workout.id]))
        #expect(sync.pendingChanges == 1)
        #expect(await sync.remoteWorkout(id: workout.id)?.workout.entries.first?.sets.count == 1)

        await sync.resolve(conflict: workout.id, keepLocal: true)
        #expect(sync.status == .idle)
        #expect(sync.pendingChanges == 0)
        #expect(remoteChanges == 0)
    }

    @Test func keepOtherAppliesRemoteAndNotifies() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = coordinator()
        let workout = try saveWorkout()
        var remoteChanges = 0
        sync.onRemoteChanges = { remoteChanges += 1 }
        await sync.start()
        sync.setActive(false)

        await sync.resolve(conflict: workout.id, keepLocal: false)
        #expect(sync.status == .idle)
        #expect(remoteChanges == 1)
        let local = try WorkoutRepository(context: container.mainContext, now: Date.init).workout(workout.id)
        #expect(local?.entries.first?.sets.count == 1)
    }

    @Test func signOutPathWipesLocalCopy() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = coordinator()
        _ = try saveWorkout()
        var resets = 0
        sync.onLocalDataReset = { resets += 1 }
        try await sync.signOutAndRemoveLocalData()
        #expect(resets == 1)
        #expect(sync.pendingChanges == 0)
        #expect(try WorkoutRepository(context: container.mainContext, now: Date.init).recent(limit: 5).isEmpty)
    }
}

/// Polls `condition` (up to 2 s) instead of sleeping a fixed time.
@MainActor
func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for condition")
}
