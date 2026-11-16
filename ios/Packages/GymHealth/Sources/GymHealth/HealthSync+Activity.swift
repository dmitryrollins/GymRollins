import Foundation
import GymCore
import GymData

/// Import (plan 39): outside workouts (workouts other apps saved to Health) and days of activity. Outside workouts come
/// incrementally from an anchored query, deletions included; days are re-read from 6 days before the last read and
/// written only when a value changed. Nothing is read before the activity types were asked for
/// (`activityPermissionsAsked`), while `canImportActivity` says no, or for a kind whose switch is off.
extension HealthSync {
    /// Days re-read on every sync, counting today: Apple Watch data lands late.
    static let activityRefreshDays = 7
    static let maxUnmatchedActivityDeletions = 1_000

    func runActivityImport() async {
        guard isEnabled, state.activityPermissionsAsked, canImportActivity() else { return }
        let run = generation
        isSyncing = true
        defer { isSyncing = false }
        var changed = false
        do {
            if state.readsOutsideWorkouts { changed = try await importOutsideWorkouts(run: run) }
            guard run == generation, isEnabled else { return }
            if state.readsActivityDays { changed = try await importActivityDays(run: run) || changed }
        } catch {
            if run == generation {
                Self.log.error("Health activity import failed: \(error.localizedDescription, privacy: .public)")
                lastError = "Couldn't read your activity from Apple Health. We'll try again next time."
            }
        }
        if changed, run == generation { onActivityChanged() }
    }

    /// Applies one anchored batch: deletions first (earlier ones whose row has since come from the cloud too), then
    /// new outside workouts. True when a row changed.
    private func importOutsideWorkouts(run: Int) async throws -> Bool {
        let start = state.activityImportStart ?? now().addingTimeInterval(-Self.importWindow)
        let changes = try await store.outsideWorkoutChanges(since: start, anchor: state.activityAnchor)
        guard run == generation, isEnabled, state.readsOutsideWorkouts else { return false }
        var changed = false
        var unmatched: [UUID] = []
        for id in state.unmatchedActivityDeletions + changes.deleted {
            if try activities.delete(id) {
                changed = true
            } else if try !activities.hasRecord(id: id) {
                unmatched.append(id)
            }
        }
        for item in changes.added {
            guard try isOutside(item), DomainLimits.healthActivityViolation(item.activity) == nil else { continue }
            // The workout's own end as the edit time, so a newer deletion from another device still wins.
            if try activities.add(item.activity, editedAt: min(item.activity.endedAt, now())) { changed = true }
        }
        let kept = Array(unmatched.suffix(Self.maxUnmatchedActivityDeletions))
        // Health answers a denied read with nothing: until a first workout came in, an empty batch isn't remembered, so
        // the next run reads the whole window again once access is granted.
        let nothingYet = state.activityAnchor == nil && changes.added.isEmpty
        update {
            if !nothingYet {
                $0.activityAnchor = changes.anchor
                $0.activityImportStart = start
            }
            $0.unmatchedActivityDeletions = kept
        }
        return changed
    }

    /// Not GymRollins' own: no export metadata or GymRollins bundle (the store tells), and no external id that is a
    /// GymRollins workout here, live or deleted.
    private func isOutside(_ item: HealthOutsideWorkout) throws -> Bool {
        guard !item.writtenByGymRollins else { return false }
        guard let id = item.externalId else { return true }
        return try workouts.workout(id) == nil && !workouts.isDeleted(id)
    }

    /// Reads from 6 days before the last read's day (two years back the first time) through today, and writes the
    /// days that are new or changed. True when one was written.
    private func importActivityDays(run: Int) async throws -> Bool {
        let time = now()
        let today = calendar.startOfDay(for: time)
        let earliest = calendar.startOfDay(for: time.addingTimeInterval(-Self.importWindow))
        let resume = state.activityDaysReadAt.flatMap {
            calendar.date(byAdding: .day, value: -(Self.activityRefreshDays - 1), to: calendar.startOfDay(for: $0))
        }
        let days = try await store.activityDays(from: max(resume ?? earliest, earliest), through: today,
                                                calendar: calendar)
        guard run == generation, isEnabled, state.readsActivityDays else { return false }
        var changed = false
        for day in days where DomainLimits.activityDayViolation(day) == nil {
            if try activities.save(day: day) { changed = true }
        }
        // The same for days: a first read that returned nothing (maybe denied) isn't remembered.
        if !days.isEmpty || state.activityDaysReadAt != nil { update { $0.activityDaysReadAt = time } }
        return changed
    }

    // MARK: Asking and the switches

    /// Health is on and the activity types were never asked for (Health was turned on by a build before plan 39).
    public var needsActivityPermission: Bool { isEnabled && !state.activityPermissionsAsked }

    /// Today's one-time "Bring in your Apple Watch activity" card.
    public var showsActivityCard: Bool { needsActivityPermission && !state.activityCardDismissed }

    /// Asks Health for the activity types (the system asks only for types never asked), then imports and exports.
    /// False (with `lastError`) when asking failed.
    @discardableResult
    public func allowActivity() async -> Bool {
        guard isEnabled else { return false }
        let started = generation
        do {
            try await store.requestAuthorization()
        } catch {
            Self.log.error("Health activity authorization failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't ask for Apple Health access. Try again."
            return false
        }
        guard started == generation else { return false }
        update { $0.activityPermissionsAsked = true }
        lastError = nil
        await sync()
        return true
    }

    /// "Not now" on Today's card: it doesn't come back (Settings › Apple Health still offers the ask).
    public func dismissActivityCard() {
        update { $0.activityCardDismissed = true }
    }

    /// "Workouts from other apps": off stops the import and hides them in the app; nothing stored is deleted.
    public func setReadsOutsideWorkouts(_ on: Bool) {
        update { $0.readsOutsideWorkouts = on }
    }

    /// "Steps & activity": the same for days of activity.
    public func setReadsActivityDays(_ on: Bool) {
        update { $0.readsActivityDays = on }
    }
}
