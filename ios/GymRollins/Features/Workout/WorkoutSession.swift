import Foundation
import GymCore
import Observation
import os

@MainActor
@Observable
final class WorkoutSession: Identifiable {
    nonisolated let id = UUID()
    private(set) var workout: Workout
    private(set) var clock: WorkoutClock
    private(set) var currentEntryId: UUID?
    /// The running rest. Every change is handed to `persistRest`, so a relaunched app (for example one started in
    /// the background by a Live Activity button) restores it.
    private(set) var rest: RestTimer? {
        didSet { if rest != oldValue { persistRest(rest) } }
    }
    /// Counts rests that ran out on their own (drives the rest-over haptic).
    private(set) var restCompletions = 0
    private(set) var lastError: String?
    var restSeconds: TimeInterval
    var warmupRestSeconds: TimeInterval
    /// Whether logging a set starts the rest timer at all (RestSettingsSheet's "Rest timer between sets" toggle).
    var restEnabled = true

    /// Set once the local data was wiped under this session: it never writes (or notifies) again.
    private(set) var isAbandoned = false
    private let notifier: RestNotifier
    private let now: () -> Date
    private let persist: (Workout, WorkoutClock) throws -> Void
    private let previousBests: (String) throws -> ExerciseBests?
    private let saveFinished: (Workout, [PersonalRecord]) throws -> Void
    private let discard: () throws -> Void
    private let persistRest: (RestTimer?) -> Void
    private static let log = Logger(subsystem: "com.rollins.gymrollins", category: "session")

    init(workout: Workout, clock: WorkoutClock, restSeconds: TimeInterval, warmupRestSeconds: TimeInterval,
         notifier: RestNotifier, now: @escaping () -> Date,
         persist: @escaping (Workout, WorkoutClock) throws -> Void,
         previousBests: @escaping (String) throws -> ExerciseBests?,
         saveFinished: @escaping (Workout, [PersonalRecord]) throws -> Void, discard: @escaping () throws -> Void,
         rest: RestTimer? = nil, persistRest: @escaping (RestTimer?) -> Void = { _ in }) {
        self.workout = workout
        self.clock = clock
        self.restSeconds = restSeconds
        self.warmupRestSeconds = warmupRestSeconds
        self.notifier = notifier
        self.now = now
        self.persist = persist
        self.previousBests = previousBests
        self.saveFinished = saveFinished
        self.discard = discard
        self.persistRest = persistRest
        self.rest = rest
        self.currentEntryId = workout.entriesWithUndoneSets.first?.id ?? workout.entries.first?.id
    }

    // MARK: Clock

    /// The session's clock (injected, fixed under UI tests).
    var currentDate: Date { now() }

    func elapsed(at date: Date) -> TimeInterval { clock.elapsed(at: date) }
    var isPaused: Bool { clock.isPaused }

    func togglePause() {
        clock = clock.isPaused ? clock.resuming(at: now()) : clock.pausing(at: now())
        save()
    }

    // MARK: Logging

    /// Moves the overview's "in progress" highlight. Logging never depends on it.
    func select(_ entryId: UUID) { currentEntryId = entryId }

    func entry(_ entryId: UUID) -> WorkoutEntry? { workout.entries.first { $0.id == entryId } }

    /// Updates the values of a set without completing it. No-op (and no save) when nothing changed.
    func update(entryId: UUID, setId: UUID, _ transform: (WorkoutSet) -> WorkoutSet) {
        let updated = workout.updatingSet(entryId: entryId, setId: setId, transform)
        guard updated != workout else { return }
        apply(updated)
    }

    /// Completes the next undone set of `entryId` with the given values and starts the rest timer,
    /// unless that was the exercise's last set (nothing left to rest before). Always acts on the
    /// entry the caller shows, never on `currentEntryId` (which may already have advanced).
    /// `sec` of nil keeps the set's existing duration.
    func logNextSet(entryId: UUID, weightKg: Double, reps: Int, sec: Int? = nil) {
        guard let entry = entry(entryId), let next = entry.sets.first(where: { !$0.done }) else { return }
        let date = now()
        apply(workout.updatingSet(entryId: entryId, setId: next.id) {
            $0.with(weightKg: weightKg, reps: reps).with(sec: sec ?? $0.sec).completing(at: date)
        })
        if !isEntryComplete(entryId) { startRest(warmup: next.warmup, at: date) }
        advanceIfComplete(entryId)
    }

    /// Rates a logged working set ("Reps left?", `SetEffort`): one tap stores the reps in reserve, tapping the
    /// selected chip clears it. Leaves the rest timer and the current exercise alone; warm-ups and undone sets are
    /// ignored.
    func rateSet(entryId: UUID, setId: UUID, tapping choice: Int) {
        guard let set = entry(entryId)?.sets.first(where: { $0.id == setId }), set.done, !set.warmup else { return }
        update(entryId: entryId, setId: setId) { $0.with(rir: SetEffort.toggled($0.rir, tapping: choice)) }
    }

    /// Completes every undone set of `entryId` and starts the rest timer, unless that finished the
    /// exercise (nothing left to rest before).
    func logAllSets(entryId: UUID) {
        guard let entry = entry(entryId) else { return }
        let date = now()
        let updated = entry.sets.filter { !$0.done }.reduce(workout) { w, set in
            w.updatingSet(entryId: entryId, setId: set.id) { $0.completing(at: date) }
        }
        apply(updated)
        if !isEntryComplete(entryId) { startRest(warmup: false, at: date) }
        advanceIfComplete(entryId)
    }

    /// The running rest at `date`, or nil. A rest that has run out is cleared here, centrally, so
    /// every screen (including one opened after it expired elsewhere) sees it as over.
    func activeRest(at date: Date) -> RestTimer? {
        guard let rest else { return nil }
        guard rest.isFinished(at: date) else { return rest }
        self.rest = nil
        restCompletions += 1
        return nil
    }

    func adjustRest(by seconds: TimeInterval) {
        guard let rest else { return }
        self.rest = rest.adjusted(by: seconds)
        notifier.schedule(endsAt: rest.adjusted(by: seconds).endsAt)
    }

    func skipRest() {
        rest = nil
        notifier.cancel()
    }

    // MARK: Editing

    func addSet(entryId: UUID) { apply(workout.appendingSet(entryId: entryId)) }

    func addWarmup(entryId: UUID, barKg: Double) {
        apply(workout.insertingWarmup(entryId: entryId, set: WorkoutSet(weightKg: barKg, reps: 10, warmup: true)))
    }

    func removeSet(entryId: UUID, setId: UUID) { apply(workout.removingSet(entryId: entryId, setId: setId)) }

    /// Replaces the entry's exercise and reconciles equipment-dependent set data: every set takes
    /// the new exercise's volume `multiplier`; undone working sets move to `workingWeightKg` when
    /// given (the new exercise's own suggestion), otherwise keep their weights.
    func swap(entryId: UUID, to exerciseId: String, multiplier: Double, workingWeightKg: Double?) {
        let replaced = workout.replacingExercise(entryId: entryId, exerciseId: exerciseId)
        let sets = replaced.entries.first { $0.id == entryId }?.sets ?? []
        let reconciled = sets.reduce(replaced) { w, set in
            w.updatingSet(entryId: entryId, setId: set.id) { current in
                let weight = !current.done && !current.warmup ? workingWeightKg ?? current.weightKg : current.weightKg
                return current.with(multiplier: multiplier).with(weightKg: weight, reps: current.reps)
            }
        }
        apply(reconciled)
    }

    func setNote(entryId: UUID, note: String?) { apply(workout.settingNote(entryId: entryId, note: note)) }

    func addExercises(_ ids: [String], makeEntry: (String) -> WorkoutEntry) {
        apply(workout.appendingEntries(ids.map(makeEntry)))
        if currentEntryId == nil { currentEntryId = workout.entries.first?.id }
    }

    func removeEntry(_ entryId: UUID) {
        apply(workout.removingEntry(entryId: entryId))
        if currentEntryId == entryId { currentEntryId = workout.entriesWithUndoneSets.first?.id ?? workout.entries.first?.id }
    }

    // MARK: Finish

    /// Completes every undone set at `date` (default now; the chosen end when finishing at the last set, so no set
    /// is stamped after the workout's end).
    func markAllDone(at date: Date? = nil) { apply(workout.markingAllDone(at: date ?? now())) }

    /// The earlier end to offer when the last set was long ago (`IdleFinish`), or nil.
    func idleFinishSuggestion() -> Date? {
        IdleFinish.suggestedEnd(completedAt: completedSetDates, clock: clock, restSeconds: restSeconds, now: now())
    }

    /// When the latest set was logged, or nil when none was.
    var lastSetAt: Date? { completedSetDates.max() }

    private var completedSetDates: [Date] { workout.entries.flatMap(\.sets).compactMap(\.completedAt) }

    /// The workout's duration if it ends at `end` (pauses excluded).
    func duration(endingAt end: Date) -> TimeInterval { clock.duration(endingAt: end) }

    /// Saves the finished workout and returns its summary (records computed against pre-save bests).
    /// `end` (default now) is when it ended: duration, calories and the Health export all follow it.
    /// On failure the workout stays in progress, `lastError` explains it, and the error is rethrown
    /// so the caller can offer a retry.
    func finish(discardingUndone: Bool, endingAt end: Date? = nil) throws -> WorkoutSummary {
        do {
            let summary = try finishOrThrow(discardingUndone: discardingUndone, end: end ?? now())
            lastError = nil
            return summary
        } catch {
            report("Couldn't finish the workout. Try again.", error)
            throw error
        }
    }

    private func finishOrThrow(discardingUndone: Bool, end: Date) throws -> WorkoutSummary {
        guard !isAbandoned else { throw CocoaError(.userCancelled) }
        let finished = workout.with(endedAt: nil, pausedSeconds: clock.pausedSeconds(endingAt: end))
            .finished(at: end, discardingUndone: discardingUndone)
        let bests = try Dictionary(uniqueKeysWithValues: Set(finished.entries.map(\.exerciseId)).compactMap { id in
            try previousBests(id).map { (id, $0) }
        })
        let summary = WorkoutSummary(workout: finished, previousBests: bests)
        try saveFinished(finished, summary.records)
        notifier.cancel()
        rest = nil
        workout = finished
        return summary
    }

    /// Deletes the in-progress workout. Returns false (and sets `lastError`) when that failed, in
    /// which case the workout is still saved and the flow must stay open.
    @discardableResult
    func discardWorkout() -> Bool {
        guard !isAbandoned else { return true }
        do {
            try discard()
            notifier.cancel()
            rest = nil
            return true
        } catch {
            report("Couldn't discard the workout. Try again.", error)
            return false
        }
    }

    /// The local data was wiped (sign-out, account switch or deletion): cancels the rest notification and makes
    /// every later edit, finish or discard a no-op, so this workout can't be written back.
    func abandon() {
        isAbandoned = true
        notifier.cancel()
        rest = nil
    }

    // MARK: Private

    private func apply(_ new: Workout) {
        workout = new
        save()
    }

    private func save() {
        guard !isAbandoned else { return }
        do { try persist(workout, clock); lastError = nil }
        catch { report("Couldn't save your last change. Keep going; we'll retry.", error) }
    }

    private func startRest(warmup: Bool, at date: Date) {
        guard restEnabled, !isAbandoned else { return }
        let timer = RestTimer(startedAt: date, duration: warmup ? warmupRestSeconds : restSeconds)
        rest = timer
        notifier.schedule(endsAt: timer.endsAt)
    }

    private func advanceIfComplete(_ entryId: UUID) {
        guard isEntryComplete(entryId) else { return }
        currentEntryId = workout.entriesWithUndoneSets.first?.id ?? entryId
    }

    private func isEntryComplete(_ entryId: UUID) -> Bool {
        entry(entryId)?.sets.allSatisfy(\.done) ?? false
    }

    private func report(_ message: String, _ error: Error) {
        Self.log.error("\(message, privacy: .public) \(error.localizedDescription, privacy: .public)")
        lastError = message
    }
}
