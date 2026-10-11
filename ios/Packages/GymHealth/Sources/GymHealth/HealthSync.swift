import Foundation
import GymCore
import GymData
import GymWatchLink
import Observation
import os

/// Keeps Apple Health in step with the app (plan 15): exports finished app workouts and app weigh-ins, imports body
/// weight / body fat. Every run is serialized, so two triggers can never interleave a delete-then-save.
@MainActor
@Observable
public final class HealthSync {
    /// `notEnabled`: Health is off. `notEligible`: this workout isn't one Health gets (imported, or finished
    /// before Health was turned on).
    public enum ExportStatus: Equatable, Sendable { case notEnabled, notEligible, pending, saved, failed }

    /// How far back the first import reads.
    public static let importWindow: TimeInterval = 2 * 365 * 86_400
    /// Weigh-ins dated up to this long before enabling are exported too (e.g. this morning's).
    static let weighInLookback: TimeInterval = 86_400
    /// Ledger value for an export that may have left something in Health but isn't known to be complete (the old
    /// copy was deleted, or a save is in flight / failed): never matches a fingerprint, and remembers whether the
    /// optional sample may exist, so a later delete cleans it up.
    static func needsRetry(optional: String, _ written: Bool) -> String { "retry|\(optional):\(written)" }

    static func isComplete(_ fingerprint: String?) -> Bool { fingerprint.map { !$0.hasPrefix("retry|") } ?? false }

    public private(set) var state: HealthSyncState
    public private(set) var permissions: HealthPermissions = .notDetermined
    /// A user-facing reason the last enable/sync failed, nil when it worked.
    public internal(set) var lastError: String?
    public internal(set) var isSyncing = false
    var failedWorkouts: Set<UUID> = []

    @ObservationIgnored let store: any HealthStore
    @ObservationIgnored let workouts: WorkoutRepository
    @ObservationIgnored let body: BodyRepository
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored let calendar: Calendar
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let estimate: @MainActor (Workout) -> CalorieEstimate?
    /// Weigh-ins were added, changed or removed by an import (the app reloads and syncs them).
    @ObservationIgnored public var onBodyChanged: @MainActor () -> Void
    @ObservationIgnored private var tail: Task<Void, Never>?
    /// Bumped by `disable`, `reset` and `localDataWasReset`: a run that started under an older generation stops
    /// at its next suspension point instead of writing into (or about) data that was just cleared.
    @ObservationIgnored private(set) var generation = 0
    static let log = Logger(subsystem: "com.rollins.gymrollins", category: "health")

    public init(store: any HealthStore, workouts: WorkoutRepository, body: BodyRepository, defaults: UserDefaults,
                estimate: @escaping @MainActor (Workout) -> CalorieEstimate?, now: @escaping () -> Date = Date.init,
                calendar: Calendar = .current, onBodyChanged: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.workouts = workouts
        self.body = body
        self.defaults = defaults
        self.estimate = estimate
        self.now = now
        self.calendar = calendar
        self.onBodyChanged = onBodyChanged
        self.state = HealthSyncState.load(from: defaults)
    }

    /// False while importing would race the first cloud pull (signed in, weigh-ins never pulled yet): an import then
    /// could re-create weigh-ins another device already has or deleted. The import waits for the next run.
    @ObservationIgnored public var canImport: @MainActor () -> Bool = { true }

    /// Who owns the local data (account id, or "local" when signed out); scopes the export ledgers.
    @ObservationIgnored public var owner: @MainActor () -> String? = { nil }

    public var isAvailable: Bool { store.isAvailable }
    public var isEnabled: Bool { state.enabled && store.isAvailable }

    public func exportStatus(for workout: Workout) -> ExportStatus {
        guard isEnabled else { return .notEnabled }
        if failedWorkouts.contains(workout.id) { return .failed }
        if Self.isComplete(state.workouts[workout.id.uuidString]) { return .saved }
        return isExportable(workout) ? .pending : .notEligible
    }

    func isExportable(_ workout: Workout) -> Bool {
        guard let since = state.enabledAt, let end = workout.endedAt else { return false }
        return workout.source == .app && end >= since
    }

    // MARK: Enable / disable

    /// Asks for access, then imports and exports. False (with `lastError`) when Health is unavailable or the
    /// request failed; a denied permission still enables (the status shows what's allowed).
    @discardableResult
    public func enable() async -> Bool {
        guard store.isAvailable else {
            lastError = "Apple Health isn't available on this device."
            return false
        }
        let started = generation
        do {
            try await store.requestAuthorization()
        } catch {
            Self.log.error("Health authorization failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't ask for Apple Health access. Try again."
            return false
        }
        guard started == generation else { return false }
        // Keeps the first enable time: workouts done while Health was off (or whose export failed) catch up.
        let owner = owner()
        update {
            $0.enabled = true
            $0.enabledAt = $0.enabledAt ?? now()
            $0.ledgerOwner = $0.ledgerOwner ?? owner
        }
        lastError = nil
        await refreshPermissions()
        await sync()
        return true
    }

    /// Stops syncing. Nothing is deleted from Health; turning it back on resumes where it left off.
    public func disable() {
        generation += 1
        // Watch claims go too: with Health off the watch must not write the running workout either (plan 17).
        update {
            $0.enabled = false
            $0.watchClaims = [:]
        }
        failedWorkouts = []
    }

    /// The local store was wiped (sign-out, account switch). Until `localDataRestored()`, a workout or weigh-in
    /// that is merely missing here is not deleted from Health (only real local deletions are); re-pulled ones match
    /// their ledger entries and aren't saved again.
    public func localDataWasReset() {
        generation += 1
        let time = now()
        update {
            $0.awaitingRestore = true
            $0.awaitingRestoreSince = time
            $0.pendingBodyFat = []
        }
        failedWorkouts = []
    }

    /// The owner's data is back (first sync round after the wipe). Same owner: the ledgers stand, so anything still
    /// missing was deleted elsewhere and leaves Health. Another owner: the ledgers are forgotten (never deleted —
    /// those workouts belong to the other account).
    public func localDataRestored(lastPull: Date?) {
        guard state.awaitingRestore, let lastPull, lastPull >= state.awaitingRestoreSince ?? .distantFuture else {
            return
        }
        let owner = owner()
        update {
            if $0.ledgerOwner != owner {
                $0.workouts = [:]
                $0.weighIns = [:]
            }
            $0.ledgerOwner = owner
            $0.awaitingRestore = false
            $0.awaitingRestoreSince = nil
        }
    }

    /// Signing in adopts the local rows for the account without a wipe: the ledgers now describe that account.
    private func adoptOwnerIfChanged() {
        let owner = owner()
        guard !state.awaitingRestore, let owner, state.ledgerOwner != owner else { return }
        update { $0.ledgerOwner = owner }
    }

    /// "Erase all data": Health off and everything forgotten (Health itself keeps what was written).
    public func reset() {
        generation += 1
        update { $0 = HealthSyncState() }
        failedWorkouts = []
        lastError = nil
    }

    public func refreshPermissions() async {
        guard store.isAvailable else { return }
        permissions = await store.permissions()
    }

    // MARK: Runs

    /// Import, then export (app launch / foreground, enable).
    public func sync() async {
        await serialized { [self] in
            await runImport()
            await runExport()
        }
    }

    /// Export only (after a local change: finish, edit, delete, weigh-in).
    public func exportChanges() async {
        await serialized { [self] in await runExport() }
    }

    public func importBody() async {
        await serialized { [self] in await runImport() }
    }

    private func serialized(_ work: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        tail = task
        await task.value
    }

    // MARK: Export

    private func runExport() async {
        guard isEnabled, let since = state.enabledAt else { return }
        let run = generation
        isSyncing = true
        defer { isSyncing = false }
        // Fresh permissions: they're part of each fingerprint, so a newly allowed type gets re-exported.
        permissions = await store.permissions()
        adoptOwnerIfChanged()
        do {
            guard run == generation, isEnabled else { return }
            try await exportWorkouts(since: since, run: run)
            guard run == generation, isEnabled else { return }
            try await exportWeighIns(since: since.addingTimeInterval(-Self.weighInLookback), run: run)
        } catch {
            Self.log.error("Health export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Eligible app workouts plus everything exported before (so edits after re-enabling still reach Health).
    private func exportWorkouts(since: Date, run: Int) async throws {
        var candidates = try workouts.finished(endedSince: since).filter { $0.source == .app }
        let eligible = Set(candidates.map(\.id.uuidString))
        for key in state.workouts.keys.sorted() where !eligible.contains(key) {
            if let id = UUID(uuidString: key), let workout = try workouts.workout(id) { candidates.append(workout) }
        }
        for workout in candidates {
            guard let item = healthWorkout(workout) else { continue }
            guard await exportWorkout(workout.id, item: item, run: run) else { return }
        }
        let live = Set(candidates.map(\.id.uuidString))
        for key in state.workouts.keys.sorted() where !live.contains(key) {
            guard run == generation else { return }
            guard let id = UUID(uuidString: key), try workouts.workout(id) == nil else { continue }
            if state.awaitingRestore, try !workouts.isDeleted(id) { continue } // wiped, not deleted
            do {
                let hadEnergy = Self.hadOptional(state.workouts[key])
                update { $0.workouts[key] = Self.needsRetry(optional: "energy", hadEnergy) } // a delete can half-succeed
                try await store.deleteWorkout(externalId: id, withEnergy: hadEnergy)
                guard run == generation else { return }
                update { $0.workouts[key] = nil }
            } catch {
                guard run == generation else { return }
                Self.log.error("Health workout delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Writes one workout to Health unless it's the watch's or unchanged. False when the run was superseded.
    private func exportWorkout(_ id: UUID, item: HealthWorkout, run: Int) async -> Bool {
        let key = id.uuidString
        let watchOwns = await leftToWatch(id, endedAt: item.end, run: run)
        guard run == generation else { return false }
        guard !watchOwns else { return true }
        let energy = allowed(.activeEnergy) && item.kcal != nil
        let fingerprint = item.fingerprint + "|energy:\(energy)"
        guard state.workouts[key] != fingerprint else {
            failedWorkouts.remove(id)
            return true
        }
        do {
            let previous = state.workouts[key]
            // Incomplete from here on (a delete can half-succeed); keeps whether energy may still be there.
            if previous != nil {
                update { $0.workouts[key] = Self.needsRetry(optional: "energy", Self.hadOptional(previous)) }
            }
            // Phone-only: the watch's recording (same external id, possibly the same HealthKit source) never goes.
            try await store.deleteOwnWorkout(externalId: id, withEnergy: Self.hadOptional(previous))
            guard run == generation else { return false }
            // The watch's confirmation landed meanwhile (nothing of the phone's was in Health): don't write.
            guard state.workouts[key] != WatchHealthRules.recordedByWatch else { return true }
            // Tracked before writing: a partly written workout (e.g. its energy sample) is cleaned up later.
            update { $0.workouts[key] = Self.needsRetry(optional: "energy", energy) }
            try await store.save(workout: item)
            guard run == generation else { return false }
            failedWorkouts.remove(id)
            update { $0.workouts[key] = fingerprint }
        } catch {
            guard run == generation else { return false }
            Self.log.error("Health workout save failed: \(error.localizedDescription, privacy: .public)")
            failedWorkouts.insert(id)
        }
        return true
    }

    private func healthWorkout(_ workout: Workout) -> HealthWorkout? {
        guard let end = workout.endedAt else { return nil }
        let estimate = estimate(workout)
        return HealthWorkout(externalId: workout.id, name: workout.name, start: workout.startedAt, end: end,
                             kcal: estimate.map { Double($0.activeKcal) },
                             activity: estimate?.healthActivity ?? .strength,
                             pausedSeconds: min(workout.pausedSeconds, max(0, end.timeIntervalSince(workout.startedAt))))
    }

    private func exportWeighIns(since: Date, run: Int) async throws {
        let all = try body.entries(since: nil).filter { $0.source == .app }
        let candidates = all.filter { $0.date >= since || state.weighIns[$0.id.uuidString] != nil }
        for entry in candidates {
            let item = HealthWeighIn(externalId: entry.id, date: entry.date, weightKg: entry.weightKg,
                                     bodyFatPct: entry.bodyFatPct)
            let key = entry.id.uuidString
            let fat = allowed(.bodyFat) && item.bodyFatPct != nil
            let fingerprint = item.fingerprint + "|fat:\(fat)"
            guard state.weighIns[key] != fingerprint else { continue }
            do {
                let previous = state.weighIns[key]
                if previous != nil {
                    update { $0.weighIns[key] = Self.needsRetry(optional: "fat", Self.hadOptional(previous)) }
                }
                try await store.deleteWeighIn(externalId: entry.id, withBodyFat: Self.hadOptional(previous))
                guard run == generation else { return }
                update { $0.weighIns[key] = Self.needsRetry(optional: "fat", fat) }
                try await store.save(weighIn: item)
                guard run == generation else { return }
                update { $0.weighIns[entry.id.uuidString] = fingerprint }
            } catch {
                guard run == generation else { return }
                Self.log.error("Health weigh-in save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let live = Set(all.map(\.id.uuidString))
        for key in state.weighIns.keys.sorted() where !live.contains(key) {
            guard run == generation else { return }
            guard let id = UUID(uuidString: key) else { continue }
            if state.awaitingRestore, try !body.hasRecord(id: id) { continue } // wiped, not deleted
            do {
                let hadFat = Self.hadOptional(state.weighIns[key])
                update { $0.weighIns[key] = Self.needsRetry(optional: "fat", hadFat) }
                try await store.deleteWeighIn(externalId: id, withBodyFat: hadFat)
                guard run == generation else { return }
                update { $0.weighIns[key] = nil }
            } catch {
                guard run == generation else { return }
                Self.log.error("Health weigh-in delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func allowed(_ type: HealthDataType) -> Bool { permissions.permission(type) == .authorized }

    /// Whether the ledger says the optional sample (energy / body fat) was written with this export.
    static func hadOptional(_ fingerprint: String?) -> Bool { fingerprint?.hasSuffix(":true") ?? false }

    // MARK: State

    func update(_ change: (inout HealthSyncState) -> Void) {
        var copy = state
        change(&copy)
        state = copy
        do { try copy.save(to: defaults) } catch {
            Self.log.error("Health state save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
