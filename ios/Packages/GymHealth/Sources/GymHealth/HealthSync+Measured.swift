import Foundation
import GymCore

/// A GymRollins workout's Apple Health data (plan 40, spec §5): what Health measured during it, and its effort rating.
/// Nothing here throws to the screen: a failed read or write is logged and answered with nil or false, and the app
/// shows its own values. Nothing is read before the activity types were asked for (plan 39: a query for types never
/// asked errors), and no effort is written before the effort types were.
extension HealthSync {
    /// nil when Health is off, unavailable, or the read failed (logged); never throws to the screen.
    public func measurements(for workout: Workout) async -> WorkoutMeasurements? {
        guard isEnabled, state.activityPermissionsAsked, let end = workout.endedAt else { return nil }
        let run = generation
        await refreshEffortAsked()
        do {
            let read = try await store.workoutMeasurements(externalId: workout.id, start: workout.startedAt, end: end)
            return run == generation && isEnabled ? read : nil
        } catch {
            guard run == generation else { return nil }
            Self.log.error("Health measurements read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// true when Health saved it; false when Health is off, not allowed, the workout has no Health copy, or the write
    /// failed (logged).
    public func rateEffort(_ score: Int, for workout: Workout) async -> Bool {
        guard Effort.range.contains(score) else { return false }
        return await writeEffort(for: workout, needsCopy: true) { store, id in
            try await store.rateEffort(externalId: id, score: score)
        }
    }

    /// true when Health no longer has GymRollins' rating (a rating made in Fitness stays); false as for `rateEffort`.
    public func clearEffort(for workout: Workout) async -> Bool {
        await writeEffort(for: workout, needsCopy: false) { store, id in
            try await store.clearEffort(externalId: id)
        }
    }

    /// true while Health is on, the activity types were asked, and the effort types were not: the Effort card's Allow
    /// pill. Unknown (false) until a measurements read has checked.
    public var effortNeedsAsking: Bool { isEnabled && state.activityPermissionsAsked && effortAsked == false }

    /// Asks for the effort types (the system shows only new types); afterwards effortNeedsAsking is false. A failed
    /// ask keeps the pill (logged, with `lastError`).
    public func askForEffort() async {
        guard isEnabled else { return }
        let started = generation
        do {
            try await store.requestAuthorization()
        } catch {
            Self.log.error("Health effort authorization failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't ask for Apple Health access. Try again."
            return
        }
        guard started == generation else { return }
        await refreshEffortAsked()
        lastError = nil
    }

    /// Asks Health (no prompt) whether the effort types were asked, and answers: plan 40's one 90-day read waits for it.
    /// `effortAsked` stays nil until something checks, and `enable()` doesn't; this also settles `effortNeedsAsking`.
    public func checkEffortAsked() async -> Bool {
        guard isEnabled else { return false }
        await refreshEffortAsked()
        return effortAsked == true
    }

    // MARK: Private

    /// Asks the store (no prompt) whether the effort types were asked; set only on a change, so observers don't redraw.
    private func refreshEffortAsked() async {
        let asked = await store.effortTypesAsked()
        if effortAsked != asked { effortAsked = asked }
    }

    /// One effort write, once Health is on and the effort types were asked. `needsCopy`: only when Health has the
    /// workout's GymRollins copy, which a rating is related to (a workout finished before Health was on has none).
    private func writeEffort(for workout: Workout, needsCopy: Bool,
                             _ write: (any HealthStore, UUID) async throws -> Void) async -> Bool {
        guard isEnabled, state.activityPermissionsAsked, let end = workout.endedAt else { return false }
        let run = generation
        await refreshEffortAsked()
        guard run == generation, effortAsked == true else { return false }
        do {
            if needsCopy {
                let held = try await store.workoutMeasurements(externalId: workout.id, start: workout.startedAt,
                                                               end: end)
                guard run == generation, isEnabled, held.recordedBy != nil else { return false }
            }
            try await write(store, workout.id)
            return true
        } catch {
            Self.log.error("Health effort write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
