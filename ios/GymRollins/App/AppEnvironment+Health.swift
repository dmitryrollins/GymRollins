import Foundation
import GymCore
import GymData
import GymHealth
import GymSync

/// Apple Health wiring (plan 15): which store backs `health`, and when it syncs.
extension AppEnvironment {
    /// The real HealthKit store, or (DEBUG `-fakeHealth`) a seeded fake. UI-test launches keep Health's state in a
    /// throwaway defaults suite, so a previous run's "enabled" never leaks into the next.
    static func makeHealth(options: LaunchOptions, defaults: UserDefaults, workouts: WorkoutRepository,
                           body: BodyRepository, calories: CalorieService, now: @escaping () -> Date) -> HealthSync {
        let (store, healthDefaults) = healthBackend(options: options, defaults: defaults, now: now)
        return HealthSync(store: store, workouts: workouts, body: body, defaults: healthDefaults,
                          estimate: { calories.estimate($0) }, now: now)
    }

    private static func healthBackend(options: LaunchOptions, defaults: UserDefaults,
                                      now: () -> Date) -> (any HealthStore, UserDefaults) {
        #if DEBUG
        let store: any HealthStore = options.fakeHealth
            ? FakeHealthStore(seed: FakeHealthStore.uiTestSeed(now: now())) : HealthKitStore()
        if options.uiTesting, let suite = UserDefaults(suiteName: "uitest.health") {
            suite.removePersistentDomain(forName: "uitest.health")
            return (store, suite)
        }
        return (store, defaults)
        #else
        return (HealthKitStore(), defaults)
        #endif
    }

    /// Called once from `init`, after every stored property is set.
    func wireHealth() {
        calories.library = { [weak self] in self?.library ?? ExerciseLibrary(exercises: []) }
        health.onBodyChanged = { [weak self] in self?.healthImportedWeighIns() }
        // Signed in: import only once a sync round (with its pull) has finished, so the import sees what other devices
        // already imported (or deleted) instead of re-creating it.
        health.canImport = { [weak self] in
            guard let self, sync.hasRestoredSession else { return false } // signed-out may just mean "not yet"
            return sync.authState == .signedOut || sync.lastSyncedAt != nil
                || syncStore.cursor(for: .bodyweight) != nil
        }
        health.owner = { [weak self] in self?.syncStore.ownerUserId?.uuidString ?? "local" }
        sync.onRoundFinished = { [weak self] in
            guard let self else { return }
            health.localDataRestored(lastPull: sync.lastSyncedAt) // no-op unless a pull succeeded after a wipe
            guard health.isEnabled, health.state.anchor == nil else { return }
            Task { await self.health.importBody() }
        }
    }

    /// Workouts/weigh-ins changed locally: bring Health up to date (no-op while it's off).
    func exportToHealth() {
        guard health.isEnabled else { return }
        Task { await health.exportChanges() }
    }

    /// Rows arrived from the cloud (possibly the first pull, which unblocks the import): import + export.
    func syncHealthAfterPull() {
        guard health.isEnabled else { return }
        Task { await health.sync() }
    }

    /// App launch / foreground: refresh the permission status, then import + export.
    func syncHealth() async {
        await health.refreshPermissions()
        await health.sync()
    }

    /// New weigh-ins came from Health: screens reload and they sync to the cloud like manual ones.
    private func healthImportedWeighIns() {
        bumpDataRevision()
        calories.invalidate()
        sync.localDataChanged()
    }

    /// DEBUG `-workoutStartedMinutesAgo`: moves a new workout's start back so fixed-clock UI tests get a duration.
    func debugStartOffset(_ workout: Workout) -> Workout {
        #if DEBUG
        if let minutes = options.workoutStartedMinutesAgo, minutes > 0 {
            let start = workout.startedAt.addingTimeInterval(-minutes * 60)
            return Workout(id: workout.id, startedAt: start, endedAt: workout.endedAt,
                           pausedSeconds: workout.pausedSeconds, routineId: workout.routineId, name: workout.name,
                           entries: workout.entries, source: workout.source, note: workout.note)
        }
        #endif
        return workout
    }
}
