import Foundation
import GymCore
import GymData

/// Import (plan 39): outside workouts, the workouts other apps saved to Health, incrementally from an anchored query,
/// deletions included. Nothing is read before the activity types were asked for (`activityPermissionsAsked`), while
/// `canImportActivity` says no, or while "Workouts from other apps" is off.
extension HealthSync {
    static let maxUnmatchedActivityDeletions = 1_000

    func runActivityImport() async {
        guard isEnabled, state.activityPermissionsAsked, canImportActivity() else { return }
        let run = generation
        isSyncing = true
        defer { isSyncing = false }
        var changed = false
        do {
            if state.readsOutsideWorkouts { changed = try await importOutsideWorkouts(run: run) }
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
        update {
            $0.activityAnchor = changes.anchor
            $0.activityImportStart = start
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

    /// "Workouts from other apps": off stops the import and hides them in the app; nothing stored is deleted.
    public func setReadsOutsideWorkouts(_ on: Bool) {
        update { $0.readsOutsideWorkouts = on }
    }
}
