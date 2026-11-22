import Foundation
import GymCore
import GymData
import GymHealth
import GymSync

/// Apple Health wiring (plan 15; activity in plan 39): which store backs `health`, and when it syncs.
extension AppEnvironment {
    /// The real HealthKit store, or (DEBUG `-fakeHealth`) a seeded fake; a test's `injected` store wins over both.
    /// UI-test launches keep Health's state in a throwaway defaults suite, so a previous run's "enabled" never leaks
    /// into the next.
    static func makeHealth(options: LaunchOptions, defaults: UserDefaults, injected: (any HealthStore)?,
                           workouts: WorkoutRepository, body: BodyRepository, activities: ActivityRepository,
                           calories: CalorieService, now: @escaping () -> Date) -> HealthSync {
        let (store, healthDefaults) = healthBackend(options: options, defaults: defaults, injected: injected,
                                                    workouts: workouts, now: now)
        return HealthSync(store: store, workouts: workouts, body: body, activities: activities,
                          defaults: healthDefaults, estimate: { calories.estimate($0) }, now: now)
    }

    private static func healthBackend(options: LaunchOptions, defaults: UserDefaults, injected: (any HealthStore)?,
                                      workouts: WorkoutRepository, now: () -> Date) -> (any HealthStore, UserDefaults) {
        #if DEBUG
        let store: any HealthStore
        if let injected {
            store = injected
        } else if options.fakeHealth {
            // The history is seeded by now, so the watch copy can be keyed by the seeded workout's id (plan 40).
            let copies = options.fakeHealthNoWatchCopy ? [:] : DebugMeasuredSeed.watchCopies(in: workouts, now: now())
            store = FakeHealthStore(seed: FakeHealthStore.uiTestSeed(now: now()),
                                    outsideWorkouts: FakeHealthStore.uiTestOutsideWorkouts(now: now())
                                        + [uiTestRide(now: now())],
                                    days: FakeHealthStore.uiTestActivityDays(now: now(), calendar: .current),
                                    measurements: copies, firstRequestAsksEffort: !options.fakeHealthEffortUnasked)
        } else {
            store = HealthKitStore()
        }
        if options.uiTesting, let suite = UserDefaults(suiteName: "uitest.health") {
            suite.removePersistentDomain(forName: "uitest.health")
            if options.healthBeforeActivity { seedHealthBeforeActivity(in: suite, now: now()) }
            return (store, suite)
        }
        return (store, defaults)
        #else
        return (injected ?? HealthKitStore(), defaults)
        #endif
    }

    #if DEBUG
    /// Plan 39's look (§4.1): an Indoor Cycle on an Indoor Bike, recorded with an Apple Watch, on the Thursday
    /// before `-fixedNow` (16:15 UTC). Synthetic values shaped like a short ride: 7 min 30 s, 3.4 km, 62 of 75
    /// kcal, 150 W, 70 rpm. Under 10 minutes, so it doesn't count toward the streak or the weekly goal.
    static let uiTestRideId = UUID(uuidString: "00000000-0000-4000-8000-00000000a003")!

    static func uiTestRide(now: Date) -> HealthOutsideWorkout {
        let start = now.addingTimeInterval(-2 * 86_400 + 7 * 3_600 + 900)
        return HealthOutsideWorkout(activity: HealthActivity(
            id: uiTestRideId, kind: "cycling", startedAt: start, endedAt: start.addingTimeInterval(450), durationS: 450,
            kcal: 62, totalKcal: 75, distanceM: 3_400, avgHr: 124, maxHr: 146, avgPowerW: 150, avgCadenceRpm: 70,
            sourceName: "Indoor Bike", fromWatch: true))
    }

    /// `-healthBeforeActivity`: Health on, as a build from before plan 39 left it (the activity types never asked).
    private static func seedHealthBeforeActivity(in suite: UserDefaults, now: Date) {
        do { try HealthSyncState.saveEnabledBeforeActivity(to: suite, at: now) } catch {
            log.error("Seed Health state failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif

    /// Called once from `init`, after every stored property is set.
    func wireHealth() {
        calories.library = { [weak self] in self?.library ?? ExerciseLibrary(exercises: []) }
        health.onBodyChanged = { [weak self] in self?.healthImportedWeighIns() }
        health.onActivityChanged = { [weak self] in self?.healthImportedActivity() }
        health.onWorkoutExported = { [weak self] in self?.measurementsAfterExport($0) }
        // Signed in: import only once a sync round (with its pull) has finished, so the import sees what other devices
        // already imported (or deleted) instead of re-creating it.
        health.canImport = { [weak self] in
            guard let self, sync.hasRestoredSession else { return false } // signed-out may just mean "not yet"
            return sync.authState == .signedOut || sync.lastSyncedAt != nil
                || syncStore.cursor(for: .bodyweight) != nil
        }
        // The same for outside workouts and days of activity, by their own cursor (plan 39).
        health.canImportActivity = { [weak self] in
            guard let self, sync.hasRestoredSession else { return false }
            return sync.authState == .signedOut || sync.lastSyncedAt != nil
                || syncStore.cursor(for: .healthActivities) != nil
        }
        health.owner = { [weak self] in self?.syncStore.ownerUserId?.uuidString ?? "local" }
        sync.onRoundFinished = { [weak self] in
            guard let self else { return }
            health.localDataRestored(lastPull: sync.lastSyncedAt) // no-op unless a pull succeeded after a wipe
            guard health.isEnabled else { return }
            if health.state.anchor == nil { Task { await self.health.importBody() } }
            if health.state.activityAnchor == nil { Task { await self.health.importActivity() } }
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

    /// App launch / foreground: refresh the permission status, then import + export. The session's Health reads of
    /// workouts are forgotten and an open detail loads again, so a rating made in Fitness meanwhile shows (spec item
    /// 22): its read is remembered, so it redraws once. The attachments are noted before the run, for
    /// `measuredAfterActivityImport` (plan 40). Then, once per account, the 90-day read after a turn-on that asked for
    /// the effort types (spec §5.5).
    func syncHealth() async {
        measuredMemo.forgetAll()
        bumpMeasuredRevision()
        rememberAttachedWorkouts()
        await health.refreshPermissions()
        await health.sync()
        await backfillMeasurementsOnce()
    }

    /// New weigh-ins came from Health: screens reload and they sync to the cloud like manual ones.
    private func healthImportedWeighIns() {
        bumpDataRevision()
        calories.invalidate()
        sync.localDataChanged()
    }

    /// Outside workouts or days of activity came from Health: screens reload, they sync to the cloud, and a GymRollins
    /// workout that gained or lost an attached recording is read again (plan 40).
    private func healthImportedActivity() {
        bumpDataRevision()
        sync.localDataChanged()
        measuredAfterActivityImport()
    }

    /// DEBUG `-workoutStartedMinutesAgo`: moves a new workout's start back so fixed-clock UI tests get a duration.
    func debugStartOffset(_ workout: Workout) -> Workout {
        #if DEBUG
        if let minutes = options.workoutStartedMinutesAgo, minutes > 0 {
            let start = workout.startedAt.addingTimeInterval(-minutes * 60)
            return Workout(id: workout.id, startedAt: start, endedAt: workout.endedAt,
                           pausedSeconds: workout.pausedSeconds, routineId: workout.routineId, name: workout.name,
                           entries: workout.entries, source: workout.source, note: workout.note,
                           gymId: workout.gymId)
        }
        #endif
        return workout
    }
}
