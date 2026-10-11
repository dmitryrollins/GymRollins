import Foundation
import GymCore
import GymData
import GymHealth
import GymSync
import Observation
import SwiftData
import os

/// App-wide dependencies. Created once at launch; injected with `.environment(env)`.
@MainActor
@Observable
final class AppEnvironment {
    let container: ModelContainer
    let now: () -> Date
    let profiles: ProfileRepository
    let routines: RoutineRepository
    let workouts: WorkoutRepository
    let body: BodyRepository
    let customExercises: CustomExerciseRepository
    let proposals: ProposalRepository
    let exercisePrefs: ExercisePreferenceRepository
    /// The owner's "recommend more / less / never" choices (normal ones left out); change them with `setPreference`.
    var exercisePreferences: [String: ExercisePreference] = [:]
    /// Exercise photos (own media -> free-exercise-db -> wger -> illustration) and their on-demand loader.
    let media: ExerciseMediaService
    /// Exercise names in other languages (wger) with their credits; search and import matching use them too.
    let otherNames: ExerciseNamesI18n?
    /// `<SUPABASE_URL>/functions/v1/mcp`, nil when this build has no Supabase config.
    let connectorURL: String?
    private let bundledLibrary: ExerciseLibrary
    private(set) var library: ExerciseLibrary
    private(set) var profile: Profile
    /// Bumps whenever routines/schedule change so screens reload.
    private(set) var planRevision = 0
    /// Bumps whenever today's plan is changed for today only (switch, add/delete exercises, set edits — anything saved
    /// to or cleared from `TodayPlanStore`), so the Apple Watch is re-sent today's title and Start.
    private(set) var todayPlanRevision = 0
    /// Bumps whenever workouts or weigh-ins are written so Log/Body screens reload.
    private(set) var dataRevision = 0
    private(set) var session: WorkoutSession?
    /// The proposal just applied from the review, for Today's "Undo" toast (cleared by undo or closing it).
    private(set) var lastApplied: (id: UUID, count: Int)?
    /// Whether onboarding (Welcome -> Today) has finished; `RootView` shows `OnboardingFlow` while false.
    private(set) var onboardingComplete: Bool
    /// Auth + sync lifecycle (sign-in state, status, triggers).
    let sync: SyncCoordinator
    let syncStore: SyncStore
    /// Calorie estimates (2024 Compendium) for Summary, Log and Apple Health.
    let calories: CalorieService
    /// Apple Health sync (opt-in; plan 15).
    let health: HealthSync
    let options: LaunchOptions
    /// Local (unsynced) preferences: warm-ups, rest, progression default.
    let defaults: UserDefaults

    static let log = Logger(subsystem: "com.rollins.gymrollins", category: "app")
    private static let onboardingCompleteKey = "onboardingComplete"

    /// `makeSync` replaces the launch's sync backend (tests inject a coordinator over a fake transport).
    init(options: LaunchOptions = LaunchOptions(), defaults: UserDefaults = .standard,
         media: ExerciseMediaService? = nil,
         makeSync: (@MainActor (SyncStore, @escaping () -> Date) -> SyncCoordinator)? = nil) throws {
        if options.resetStore, let storeURL = options.diskStoreURL {
            Self.removeStoreFiles(at: storeURL)
        }
        let container = try GymStore.container(inMemory: options.inMemory && options.diskStoreURL == nil,
                                               url: options.diskStoreURL)
        let fixed = options.fixedNow
        let now: () -> Date = { fixed ?? Date() }
        let context = container.mainContext
        let syncStore = SyncStore(context: context, defaults: defaults, now: now)
        if options.resetStore { try syncStore.resetAll() } // a fresh store must not reuse old pull cursors
        // Today's switched/edited plan (UserDefaults) was made from the previous store's data: an in-memory or reset
        // store starts without it (UI tests share one day via -fixedNow, so a leftover plan leaked between tests).
        if Self.startsWithFreshStore(options) { Self.clearTodaySwitches(in: defaults) }
        if options.seedOwner {
            try OwnerSeed.apply(to: context, now: now())
            if options.seedHistory { try OwnerSeed.applyHistory(to: context, now: now()) }
            if options.seedBodyweight { try OwnerSeed.applyBodyweight(to: context, now: now()) }
            if options.seedPlank { try OwnerSeed.applyPlank(to: context, now: now()) }
            if options.seedLargeHistory {
                try OwnerSeed.applyLargeHistory(to: context, now: now(), count: options.largeHistoryCount)
            }
        }
        #if DEBUG
        if options.seedProposal { try DebugProposalSeed.apply(context: context, now: now()) }
        if options.seedTodayProposal { try DebugProposalSeed.applyToday(context: context, now: now()) }
        if options.seedInsights { try DebugInsightsSeed.apply(context: context, now: now()) }
        if options.seedStrength { try DebugStrengthSeed.apply(context: context, now: now()) }
        #endif
        guard let url = Bundle.main.url(forResource: "exercises", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        self.container = container
        self.now = now
        self.options = options
        self.defaults = defaults
        self.profiles = ProfileRepository(context: context, now: now)
        self.routines = RoutineRepository(context: context, now: now)
        self.workouts = WorkoutRepository(context: context, now: now)
        self.body = BodyRepository(context: context, now: now)
        self.customExercises = CustomExerciseRepository(context: context, now: now)
        self.proposals = ProposalRepository(context: context, now: now)
        self.exercisePrefs = ExercisePreferenceRepository(context: context, now: now)
        self.connectorURL = SyncCoordinator.connectorURL(options: options)
        self.media = media ?? ExerciseMediaService.make(options: options)
        let otherNames = ExerciseNamesI18n.bundled()
        self.otherNames = otherNames
        self.bundledLibrary = try ExerciseLibrary.load(from: url, otherNames: otherNames?.searchNames ?? [:],
                                                       importNames: otherNames?.importNames ?? [:])
        self.library = bundledLibrary.merging(custom: try customExercises.all())
        self.profile = try profiles.load()
        self.exercisePreferences = try exercisePrefs.all()
        let hasExistingData = ((try? self.routines.all().isEmpty) == false)
        self.onboardingComplete = Self.resolveOnboardingComplete(options: options, defaults: defaults,
                                                                  hasExistingData: hasExistingData)
        self.syncStore = syncStore
        self.sync = makeSync?(syncStore, now) ?? SyncCoordinator.make(options: options, store: syncStore, now: now)
        let calories = CalorieService(library: { [bundledLibrary] in bundledLibrary }, body: body)
        self.calories = calories
        self.health = Self.makeHealth(options: options, defaults: defaults, workouts: workouts, body: body,
                                      calories: calories, now: now)
        restoreSession()
        sync.autoApply = { [weak self] in try self?.autoApplyPulledProposals() ?? 0 }
        autoApplyProposals() // proposals pulled earlier, or seeded, while auto-apply is on
        sync.onRemoteChanges = { [weak self] in
            self?.reloadAll()
            self?.syncHealthAfterPull()
        }
        sync.onLocalDataReset = { [weak self] in
            ExportService.removeExportFiles() // never share a file built from the previous account's data
            self?.health.localDataWasReset()
            if let defaults = self?.defaults { Self.clearTodaySwitches(in: defaults) }
            self?.abandonSession()
            self?.reloadAll()
        }
        wireHealth()
    }

    func setLastApplied(_ value: (id: UUID, count: Int)?) { lastApplied = value }

    /// True once any routine exists (seeded, imported or created): onboarding's "offer a template" step only
    /// applies to a genuinely empty plan.
    var hasAnyRoutine: Bool { (try? routines.all().isEmpty) == false }

    /// Finishes onboarding: optionally seeds the owner's Push/Pull/Upper/Legs split (no history) when the
    /// plan is empty, then marks onboarding complete so `RootView` shows the main tabs.
    func completeOnboarding(useTemplate: Bool) {
        if useTemplate {
            do {
                try OwnerSeed.applyTemplate(to: container.mainContext, now: now())
                planChanged()
            } catch {
                Self.log.error("Apply template failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        onboardingComplete = true
        defaults.set(true, forKey: Self.onboardingCompleteKey)
    }

    /// `-onboarding` always forces the flow (even under `-uiTesting`); `-uiTesting`/`-skipOnboarding` always
    /// skip it (so the flags never depend on whatever a previous run persisted); a real launch with neither
    /// flag falls back to the persisted value, defaulting to "complete" when the plan already has data (an
    /// existing install migrating onto this build) and to "not complete" on a genuinely first launch.
    private static func resolveOnboardingComplete(options: LaunchOptions, defaults: UserDefaults,
                                                  hasExistingData: Bool) -> Bool {
        if options.forceOnboarding { return false }
        if options.uiTesting || options.skipOnboarding {
            defaults.set(true, forKey: onboardingCompleteKey)
            return true
        }
        if defaults.object(forKey: onboardingCompleteKey) != nil {
            return defaults.bool(forKey: onboardingCompleteKey)
        }
        if hasExistingData {
            defaults.set(true, forKey: onboardingCompleteKey)
            return true
        }
        return false
    }

    /// Settings' "Erase all data on this iPhone" (signed-out only): wipes the local store and returns to
    /// onboarding, as if this were a fresh install. A signed-in deletion goes through
    /// `SyncCoordinator.deleteAccount()` instead, which also deletes the account's data on the server.
    func eraseAllLocalData() throws {
        ExportService.removeExportFiles()
        abandonSession()
        try syncStore.resetAll()
        health.reset()
        todayPlanStore.clear()
        PlannedSwitchStore(defaults: defaults).clear()
        onboardingComplete = false
        defaults.set(false, forKey: Self.onboardingCompleteKey)
        reloadAll()
    }

    func reloadLibrary() {
        do { library = bundledLibrary.merging(custom: try customExercises.all()) }
        catch { Self.log.error("Reload library failed: \(error.localizedDescription, privacy: .public)") }
    }

    func reloadProfile() {
        do { profile = try profiles.load() }
        catch { Self.log.error("Reload profile failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// A routine or the schedule changed locally: screens reload and a sync is scheduled.
    func planChanged() {
        planRevision += 1
        sync.localDataChanged()
    }

    /// A workout or weigh-in was written locally: screens reload and a sync is scheduled.
    func dataChanged() {
        dataRevision += 1
        calories.invalidate()
        sync.localDataChanged()
        exportToHealth()
    }

    /// Today's plan was saved or cleared for today (`todayPlanStore`).
    func todayPlanChanged() { todayPlanRevision += 1 }

    /// Screens that show workouts or weigh-ins reload (without scheduling a sync).
    func bumpDataRevision() { dataRevision += 1 }

    /// A custom exercise changed locally.
    func libraryChanged() {
        reloadLibrary()
        sync.localDataChanged()
    }

    /// Remote rows were applied (or the local copy was wiped): reload everything screens show, without
    /// scheduling another sync.
    private func reloadAll() {
        calories.invalidate()
        reloadProfile()
        reloadLibrary()
        reloadExercisePreferences()
        planRevision += 1
        dataRevision += 1
    }

    /// Restores an in-progress workout after relaunch.
    func restoreSession() {
        do {
            guard let workout = try workouts.active(), let clock = try workouts.activeClock() else { return }
            session = makeSession(workout: workout, clock: clock)
        } catch {
            Self.log.error("Restore session failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Starts a workout, or keeps the one already in progress: `saveActive` replaces the stored active
    /// workout, so starting over an existing session would silently delete its logged sets. Callers show
    /// "Resume" when `session` is set; this guard makes that the only outcome.
    func startSession(routine: Routine?, setOverrides: [UUID: [WorkoutSet]] = [:], restSec: Int? = nil) {
        guard session == nil else {
            Self.log.notice("Start session ignored: a workout is already in progress")
            return
        }
        let planned = routine.map {
            SessionPlanner.start(routine: $0, profile: profile, library: library, now: now(),
                                 history: { [workouts] in (try? workouts.history(exerciseId: $0, limit: 5)) ?? [] },
                                 autoWarmups: WarmupPreferences.autoWarmupsEnabled(defaults), setOverrides: setOverrides)
        } ?? SessionPlanner.empty(now: now())
        let workout = debugStartOffset(planned)
        // Today's rest (if set) goes with this workout, so a relaunch restores it too (`makeSession`).
        ActiveRestDurationStore(defaults: defaults).save(restSec, workoutId: workout.id)
        let session = makeSession(workout: workout, clock: WorkoutClock(startedAt: workout.startedAt))
        do { try workouts.saveActive(workout, pausedAt: nil) }
        catch { Self.log.error("Start session save failed: \(error.localizedDescription, privacy: .public)") }
        self.session = session
    }

    func endSession() { session = nil }

    /// The local copy was wiped: the in-progress workout (already deleted from the store) must not come back
    /// through its session, and its rest notification must not fire.
    private func abandonSession() {
        session?.abandon()
        session = nil
    }

    private func makeSession(workout: Workout, clock: WorkoutClock) -> WorkoutSession {
        let repo = workouts
        let defaults = self.defaults
        let notifier: RestNotifier = options.inMemory
            ? NoopRestNotifier()
            : UserNotificationRestNotifier(now: now, soundEnabled: { RestPreferences.soundEnabled(defaults) })
        let restStore = ActiveRestStore(defaults: defaults)
        let workoutId = workout.id
        let session = WorkoutSession(
            workout: workout, clock: clock,
            restSeconds: TimeInterval(profile.restSec), warmupRestSeconds: TimeInterval(profile.warmupRestSec),
            notifier: notifier,
            now: now,
            persist: { w, c in try repo.saveActive(w.with(endedAt: nil, pausedSeconds: c.pausedSeconds), pausedAt: c.pausedAt) },
            previousBests: { try repo.bests(exerciseId: $0) },
            saveFinished: { try repo.save($0, records: $1) },
            discard: { try repo.discardActive() },
            // A rest that ran out while the app was gone is over: restoring it would replay the rest-over haptic.
            rest: restStore.load(workoutId: workoutId).flatMap { $0.isFinished(at: now()) ? nil : $0 },
            persistRest: { restStore.save($0, workoutId: workoutId) })
        session.restEnabled = RestPreferences.restEnabled(defaults)
        if let seconds = ActiveRestDurationStore(defaults: defaults).load(workoutId: workoutId) {
            session.restSeconds = TimeInterval(seconds)
        }
        return session
    }

    /// True when this launch's store holds none of an earlier launch's data: in-memory (UI tests without
    /// `-diskStore`) or reset (`-resetStore`). A `-diskStore` relaunch keeps its data, and so today's plan.
    static func startsWithFreshStore(_ options: LaunchOptions) -> Bool {
        (options.inMemory && options.diskStoreURL == nil) || options.resetStore
    }

    /// Deletes a SwiftData store file and its `-shm`/`-wal` siblings, ignoring not-found errors.
    private static func removeStoreFiles(at url: URL) {
        let fm = FileManager.default
        let siblings = ["-shm", "-wal"].map { URL(fileURLWithPath: url.path + $0) }
        for candidate in [url] + siblings where fm.fileExists(atPath: candidate.path) {
            do { try fm.removeItem(at: candidate) }
            catch { Self.log.error("Remove store file failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
