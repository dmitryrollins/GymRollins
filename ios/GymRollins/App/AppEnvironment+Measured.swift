import Foundation
import GymCore
import GymData
import GymHealth

/// A workout's Apple Health data in the app (plan 40, spec §5): the summary its detail shows, the snapshot saved and
/// synced whenever those numbers change, and effort rated here. Health is read once per workout per session
/// (`MeasuredMemo`) and again after the hooks of spec §5.5. It never blocks the screen: with Health off, or a read
/// that failed (logged by `HealthSync`), the summary is the app's own values.
extension AppEnvironment {
    /// How a rating was kept: always in the app (and synced); `savedInAppOnly` when Health is on and allowed but didn't
    /// take it, which the Effort card says ("Couldn't save to Apple Health").
    enum EffortSave: Equatable { case saved, savedInAppOnly }

    // MARK: Reading

    /// The detail's summary: this session's read when nothing it depends on changed, else a fresh one, whose snapshot
    /// is saved when its numbers changed.
    func measuredSummary(for workout: Workout) async -> MeasuredSummary {
        if let cached = measuredMemo.summary(for: workout.id, key: measuredKey) { return cached }
        return await readMeasurements(workout).summary
    }

    /// What the detail draws before Health answers: this session's read, else the app's own values (the estimate, an
    /// attached recording, the saved effort) with no readings, so no charts yet.
    func immediateMeasuredSummary(for workout: Workout) -> MeasuredSummary {
        measuredMemo.summary(for: workout.id, key: measuredKey)
            ?? summarize(workout, measurements: nil, saved: savedSnapshot(workout.id))
    }

    /// Re-reads and saves these workouts' numbers (spec §5.5's hooks and the 90-day backfill); an id with no finished
    /// workout is skipped. An open detail redraws. Answers how many reads Health answered (not off, not refused, not
    /// failed), for the backfill. `clearsWhenEmpty` lets an empty answer clear saved numbers: only the import hook
    /// asks for it, for a recording removed from the workout (`readMeasurements`).
    @discardableResult
    func refreshMeasurements(for workoutIds: [UUID], clearsWhenEmpty: Bool = false) async -> Int {
        var answered = 0
        for id in workoutIds {
            guard let workout = finishedWorkout(id) else { continue }
            measuredMemo.forget(id)
            if await readMeasurements(workout, clearsWhenEmpty: clearsWhenEmpty).answered { answered += 1 }
        }
        bumpMeasuredRevision()
        return answered
    }

    // MARK: Effort

    /// Rates the workout's effort 1–10 (spec §5.4): kept in the app (and synced) whatever Health does, and written to
    /// Health when it's on and allowed. Out-of-range scores are ignored.
    func rateEffort(_ score: Int, for workout: Workout) async -> EffortSave {
        guard Effort.range.contains(score) else { return .saved }
        saveEffort(score, for: workout)
        let written = await health.rateEffort(score, for: workout)
        measuredMemo.forget(workout.id)
        await readMeasurements(workout)
        bumpMeasuredRevision()
        return written || !healthTakesEffort ? .saved : .savedInAppOnly
    }

    /// Clears the app's rating and GymRollins' own one in Health. Health's estimate, or a rating made in Fitness, shows
    /// again after the re-read.
    func clearEffort(for workout: Workout) async {
        saveEffort(nil, for: workout)
        if health.isEnabled { _ = await health.clearEffort(for: workout) }
        measuredMemo.forget(workout.id)
        await readMeasurements(workout)
        bumpMeasuredRevision()
    }

    // MARK: Hooks (spec §5.5)

    /// The watch saved this workout to Health: read what it measured. The phone has normally saved the finish by
    /// then; a workout that isn't finished here yet is read once it is (`readWorkoutsTheWatchRecorded`), because a row
    /// is kept only for a finished workout.
    func healthRecordedByWatch(_ workoutId: UUID) {
        guard finishedWorkout(workoutId) != nil else {
            measuredMemo.awaitingFinish.insert(workoutId)
            return
        }
        Task { await refreshMeasurements(for: [workoutId]) }
    }

    /// A workout was written here (`dataChanged()`): the watch-recorded ones that weren't finished then are read now.
    func readWorkoutsTheWatchRecorded() {
        let finished = measuredMemo.awaitingFinish.filter { finishedWorkout($0) != nil }
        guard !finished.isEmpty else { return }
        measuredMemo.awaitingFinish.subtract(finished)
        Task { await refreshMeasurements(for: finished.sorted { $0.uuidString < $1.uuidString }) }
    }

    /// The phone's export wrote this workout's copy: heart rate from a watch worn during it, effort.
    func measurementsAfterExport(_ workoutId: UUID) {
        Task { await refreshMeasurements(for: [workoutId]) }
    }

    /// Plan 39's import changed outside workouts: the GymRollins workouts that gained or lost an attached recording
    /// since the last import are read again. Only one that lost it may be cleared (`clearsWhenEmpty`), and only of that
    /// recording's numbers; one that gained it never is. Nothing attaches while "Workouts from other apps" is off.
    func measuredAfterActivityImport() {
        guard health.state.readsOutsideWorkouts else { return }
        let attached = attachedWorkoutIds()
        let changes = Self.attachmentChanges(from: measuredMemo.attachedWorkouts ?? [], to: attached)
        measuredMemo.attachedWorkouts = attached
        guard !changes.lost.isEmpty || !changes.gained.isEmpty else { return }
        Task {
            if !changes.lost.isEmpty { await refreshMeasurements(for: changes.lost, clearsWhenEmpty: true) }
            if !changes.gained.isEmpty { await refreshMeasurements(for: changes.gained) }
        }
    }

    /// The GymRollins workouts that lost an attached recording and those that gained one between two looks, each
    /// sorted.
    static func attachmentChanges(from before: Set<UUID>, to after: Set<UUID>) -> (lost: [UUID], gained: [UUID]) {
        let sorted: (Set<UUID>) -> [UUID] = { $0.sorted { $0.uuidString < $1.uuidString } }
        return (sorted(before.subtracting(after)), sorted(after.subtracting(before)))
    }

    /// The baseline `measuredAfterActivityImport` compares with, taken before the launch's first Health run.
    func rememberAttachedWorkouts() {
        guard measuredMemo.attachedWorkouts == nil, health.state.readsOutsideWorkouts else { return }
        measuredMemo.attachedWorkouts = attachedWorkoutIds()
    }

    /// The Effort card's Allow pill (spec §5.2): asks for the effort types, then the one 90-day read.
    func allowHealthEffort() async {
        await health.askForEffort()
        await backfillMeasurementsOnce()
    }

    /// Spec §5.5's "once after the new permission is granted": the first time Health is on with the effort types asked
    /// (after the Allow pill, or on the next `syncHealth()` after a turn-on anywhere), the finished workouts of the last
    /// 90 days are read and saved, once per account. It waits for the account's first pull (`canImportActivity`), so a
    /// fresh sign-in never marks an empty store as done. Older workouts get theirs when their detail opens.
    func backfillMeasurementsOnce() async {
        let owner = measuredOwner
        guard !measuredMemo.backfilling, health.isEnabled, defaults.string(forKey: Self.measuredBackfillKey) != owner,
              health.canImportActivity() else { return }
        // Marked before the first wait: a second call meanwhile (the Allow pill during a sync) leaves it to this one.
        measuredMemo.backfilling = true
        defer { measuredMemo.backfilling = false }
        guard await health.checkEffortAsked() else { return }
        let since = now().addingTimeInterval(-Self.effortBackfillDays * 86_400)
        let ids: [UUID]
        do { ids = try measurements.finishedWorkoutIds(since: since) } catch {
            Self.log.error("Measurements backfill failed: \(error.localizedDescription, privacy: .public)")
            return // tried again on the next launch or foreground
        }
        measuredMemo.forgetAll()
        let answered = await refreshMeasurements(for: ids)
        // Marked done only now: killed partway, the next launch reads them again (unchanged numbers aren't re-saved).
        // Nor when Health answered none of the reads (each failure is logged by `HealthSync`), or the account changed
        // meanwhile (a sign-out or a switch): the next launch or foreground runs it again, for the account then.
        guard ids.isEmpty || answered > 0 else {
            Self.log.notice("Measurements backfill: Health answered none of \(ids.count) reads; runs again later")
            return
        }
        guard measuredOwner == owner else { return }
        defaults.set(owner, forKey: Self.measuredBackfillKey)
    }

    /// How far back the one read goes (spec §5.5).
    static let effortBackfillDays: TimeInterval = 90

    /// UserDefaults: the account (`measuredOwner`) whose last 90 days were read, as plan 38's one-time cleanup keeps
    /// `PlanWeightsLbCleanup.flagKey`. Per account, as plan 39's import progress: another account's workouts get theirs.
    static let measuredBackfillKey = "measuredBackfillOwner"

    /// The signed-in account, or "local" signed out: the same owner Health's ledgers use.
    private var measuredOwner: String { syncStore.ownerUserId?.uuidString ?? "local" }

    private func attachedWorkoutIds() -> Set<UUID> { Set(resolvedActivities().attachedTo.values) }

    // MARK: Private

    /// What a remembered read depends on besides the workout: the app's data, Health on or off, plan 39's switch.
    private var measuredKey: MeasuredMemo.Key {
        MeasuredMemo.Key(dataRevision: dataRevision, healthOn: health.isEnabled,
                         readsOutsideWorkouts: health.state.readsOutsideWorkouts)
    }

    /// Health should have taken a rating: it's on, and both the activity and the effort types were asked.
    private var healthTakesEffort: Bool {
        health.isEnabled && health.state.activityPermissionsAsked && !health.effortNeedsAsking
    }

    /// Reads Health, remembers the summary for the session, and saves its snapshot when the numbers changed. A read
    /// that a newer one overtook (a hook, a rating or a clear started meanwhile) keeps and saves nothing, so its fewer
    /// numbers never replace the newer ones; it answers with the newer read's summary if it's in.
    /// When Health couldn't be read (off, not asked, a failed read: nil) the app's values show but aren't saved.
    /// An empty answer (no copy, no readings) with no attached recording doesn't replace saved measured numbers either:
    /// HealthKit answers that way when read access was taken away, and on a new phone before Health's iCloud sync
    /// arrives, so it doesn't mean the numbers went. The saved row is kept and shown instead (`savedRowToKeep`).
    @discardableResult
    private func readMeasurements(_ workout: Workout, clearsWhenEmpty: Bool = false) async
        -> (summary: MeasuredSummary, answered: Bool) {
        let key = measuredKey // what the read starts from: a change meanwhile makes the next open read again
        let ticket = measuredMemo.ticket(for: workout.id)
        let read = await health.measurements(for: workout)
        let saved = savedSnapshot(workout.id)
        let kept = read.flatMap { savedRowToKeep(saved, against: $0, of: workout, clearsWhenEmpty: clearsWhenEmpty) }
        let summary = kept.map { keptSummary($0, for: workout) }
            ?? summarize(workout, measurements: read, saved: saved)
        guard measuredMemo.remember(summary, for: workout.id, key: key, ticket: ticket) else {
            return (measuredMemo.lastSummary(for: workout.id) ?? summary, read != nil)
        }
        if read != nil, kept == nil { saveSnapshot(of: summary, for: workout.id, replacing: saved) }
        return (summary, read != nil)
    }

    /// The saved row to keep against Health's answer: Health answered with nothing for the workout (no copy, no
    /// readings), no recording is attached, and the row has numbers something measured. Such a row then changes only
    /// through the app's rating (`saveEffort`), or with `clearsWhenEmpty` (the import hook saw the workout's recording
    /// go) when it holds that recording's own numbers (`appleWorkout`); a watch row always stays.
    private func savedRowToKeep(_ saved: MeasurementSnapshot?, against read: WorkoutMeasurements, of workout: Workout,
                                clearsWhenEmpty: Bool) -> MeasurementSnapshot? {
        guard let saved, saved.hasMeasuredNumbers, read.recordedBy == nil, read.heartRate.isEmpty,
              read.postWorkout.isEmpty, measuredActivity(for: workout) == nil else { return nil }
        return clearsWhenEmpty && saved.recordedBy == .appleWorkout ? nil : saved
    }

    /// A kept row as the detail shows it: its numbers and effort, and no readings, so no charts. A recording's row
    /// is named by `keptRecordingSource`, as the recording itself isn't in the phone's Health now.
    private func keptSummary(_ saved: MeasurementSnapshot, for workout: Workout) -> MeasuredSummary {
        let source: MeasuredSummary.Source = switch saved.recordedBy {
        case .watch: .watch
        case .appleWorkout: .attached(sourceName: Self.keptRecordingSource)
        case nil: .estimate
        }
        let measured = source != .estimate
        let ownDuration = appDuration(of: workout)
        return MeasuredSummary(source: source, workoutTime: measured ? saved.durationS ?? ownDuration : ownDuration,
                               activeKcal: saved.activeKcal, totalKcal: saved.totalKcal,
                               estimatedKcal: measured ? nil : calories.estimate(workout)?.kcal,
                               avgHr: saved.avgHr, maxHr: saved.maxHr, heartRate: [], postWorkout: [],
                               lastPostHr: nil, postHr: saved.postHr,
                               effort: saved.effort.flatMap { Effort(score: $0, estimated: saved.effortEstimated) })
    }

    /// Who measured a kept recording's row: Health doesn't say any more.
    static let keptRecordingSource = "Apple Health"

    /// The app's own duration: start to end, pauses left out.
    private func appDuration(of workout: Workout) -> TimeInterval {
        let end = workout.endedAt ?? workout.startedAt
        return max(0, end.timeIntervalSince(workout.startedAt) - workout.pausedSeconds)
    }

    /// The one rule (`WorkoutMeasuredRules`) on this workout's Health read, its attached recording, the estimate and
    /// the app's own rating (a saved effort that isn't the Apple Watch's estimate).
    private func summarize(_ workout: Workout, measurements read: WorkoutMeasurements?,
                           saved: MeasurementSnapshot?) -> MeasuredSummary {
        let end = workout.endedAt ?? workout.startedAt
        let appEffort = saved.flatMap { snapshot in
            snapshot.effortEstimated ? nil : snapshot.effort.flatMap { Effort(score: $0, estimated: false) }
        }
        return WorkoutMeasuredRules.summary(
            start: workout.startedAt, end: end, appDuration: appDuration(of: workout),
            measurements: read, attached: measuredActivity(for: workout),
            estimateKcal: calories.estimate(workout)?.kcal, appEffort: appEffort)
    }

    private func savedSnapshot(_ workoutId: UUID) -> MeasurementSnapshot? {
        do { return try measurements.snapshot(for: workoutId) } catch {
            Self.log.error("Load measurements failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Saves the summary's row. With nothing measured any more (a cleared rating, a removed recording) an empty row
    /// replaces the old one, so the cloud and agents stop seeing it.
    private func saveSnapshot(of summary: MeasuredSummary, for workoutId: UUID, replacing saved: MeasurementSnapshot?) {
        let time = now()
        if let snapshot = summary.snapshot(workoutId: workoutId, at: time) {
            persist(snapshot)
        } else if saved != nil {
            persist(Self.emptySnapshot(workoutId, at: time))
        }
    }

    /// The app's own rating on the numbers saved before (or, never saved, this session's read).
    private func saveEffort(_ score: Int?, for workout: Workout) {
        let base = savedSnapshot(workout.id)
            ?? measuredMemo.lastSummary(for: workout.id)?.snapshot(workoutId: workout.id, at: now())
        persist(MeasurementSnapshot(workoutId: workout.id, recordedBy: base?.recordedBy, durationS: base?.durationS,
                                    activeKcal: base?.activeKcal, totalKcal: base?.totalKcal, avgHr: base?.avgHr,
                                    maxHr: base?.maxHr, postHr: base?.postHr, effort: score, effortEstimated: false,
                                    clientUpdatedAt: now()))
    }

    /// Saved and marked for sync. The repository skips unchanged numbers and a workout that isn't finished and live
    /// (false), and throws for a row out of range: checked first, and any throw is logged, never shown.
    private func persist(_ snapshot: MeasurementSnapshot) {
        guard snapshot.isValid else {
            Self.log.error("Measurements out of range for \(snapshot.workoutId, privacy: .public): not saved")
            return
        }
        do {
            if try measurements.save(snapshot) { sync.localDataChanged() }
        } catch {
            Self.log.error("Save measurements failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func emptySnapshot(_ workoutId: UUID, at date: Date) -> MeasurementSnapshot {
        MeasurementSnapshot(workoutId: workoutId, recordedBy: nil, durationS: nil, activeKcal: nil, totalKcal: nil,
                            avgHr: nil, maxHr: nil, postHr: nil, effort: nil, effortEstimated: false,
                            clientUpdatedAt: date)
    }

    private func finishedWorkout(_ id: UUID) -> Workout? {
        do { return try workouts.workout(id).flatMap { $0.endedAt == nil ? nil : $0 } } catch {
            Self.log.error("Load workout failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// This session's Health reads (spec §5.5: one per workout, kept until the workout's data, Health or plan 39's switch
/// changes, or the app comes back to the foreground), and the workouts that had an attached recording when the
/// activity import last finished (Task 13).
struct MeasuredMemo {
    struct Key: Equatable {
        let dataRevision: Int
        let healthOn: Bool
        let readsOutsideWorkouts: Bool
    }

    /// When a read started: it's kept only if no `forget` of its workout, and no `reset`, came after.
    struct Ticket: Equatable {
        fileprivate let epoch: Int
        fileprivate let generation: Int
    }

    private var reads: [UUID: (key: Key, summary: MeasuredSummary)] = [:]
    /// Bumped by `forget(_:)`, per workout: a re-read after a write (a rating, a clear, a hook) wins.
    private var generations: [UUID: Int] = [:]
    /// Bumped by `reset()`: a read started for the previous account is refused.
    private var epoch = 0
    /// The 90-day read is running (`backfillMeasurementsOnce`); `forgetAll()` leaves it.
    var backfilling = false
    /// The GymRollins workouts with an attached recording when last looked; nil before the first look.
    var attachedWorkouts: Set<UUID>?
    /// Workouts the watch said it saved to Health before the phone had them finished; read once they are.
    var awaitingFinish: Set<UUID> = []

    /// The remembered read, while nothing it depends on changed.
    func summary(for id: UUID, key: Key) -> MeasuredSummary? {
        reads[id].flatMap { $0.key == key ? $0.summary : nil }
    }

    /// The last read whatever changed since: the numbers a rating is saved with when nothing was saved yet.
    func lastSummary(for id: UUID) -> MeasuredSummary? { reads[id]?.summary }

    func ticket(for id: UUID) -> Ticket { Ticket(epoch: epoch, generation: generations[id] ?? 0) }

    /// Keeps the read unless a newer one started after `ticket` was taken; says whether it did.
    @discardableResult
    mutating func remember(_ summary: MeasuredSummary, for id: UUID, key: Key, ticket: Ticket) -> Bool {
        guard ticket == self.ticket(for: id) else { return false }
        reads[id] = (key, summary)
        return true
    }

    mutating func forget(_ id: UUID) {
        reads[id] = nil
        generations[id, default: 0] += 1
    }

    /// Read again next time (a return to the foreground); a read already running is current enough, and is kept.
    mutating func forgetAll() { reads = [:] }

    /// A sign-out, an account switch or an erase: the reads, the attachments and the workouts waiting for a finish
    /// were the old account's, and reads still running are refused when they end. `backfilling` stays: the running
    /// 90-day read clears it when it ends, and its reads are refused too.
    mutating func reset() {
        reads = [:]
        generations = [:]
        epoch += 1
        attachedWorkouts = nil
        awaitingFinish = []
    }
}

private extension MeasurementSnapshot {
    /// Something measured the workout: the watch or an attached recording, or heart rate.
    var hasMeasuredNumbers: Bool {
        recordedBy != nil || durationS != nil || activeKcal != nil || totalKcal != nil || avgHr != nil
            || maxHr != nil || postHr != nil
    }
}
