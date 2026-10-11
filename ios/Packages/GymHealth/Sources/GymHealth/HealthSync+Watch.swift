import Foundation
import GymWatchLink

// Apple Watch (plan 17): when the watch's workout session records a workout, the watch writes the Health workout (with
// heart rate and measured energy) and the phone's exporter leaves it alone — one Health workout, the measured one
// whenever it exists.
//
// Single-copy rules:
// - Claimed, not confirmed yet: the phone waits (`WatchHealthRules.phoneFallbackDelay`).
// - Confirmation arrives (`markRecordedByWatch`) and the phone hasn't written anything: recorded by the watch for good,
//   however late it comes.
// - Confirmation overdue: before exporting, the phone looks in Health for a copy with this workout's external id from
//   another source (the watch's samples sync to the phone's Health store). Found: recorded by the watch, never
//   exported. Not found: the phone exports its estimate.
// - Confirmation arrives after the phone wrote its copy (or mid-write): remembered (`watchAcks`); each export run looks
//   for the watch's copy and, once it's seen, deletes only the phone's own copy (external id + this app's source) and
//   keeps the measured one. Not seen within `watchAckWindow` (e.g. Health replaced it with the phone's newer version
//   under the shared sync identifier, or workouts can't be read): the phone's copy stays — never zero copies.
extension HealthSync {
    /// How long after a confirmation that came too late the phone keeps looking for the watch's copy in Health.
    public static let watchAckWindow: TimeInterval = 86_400

    /// The watch's workout session will write this (running) workout to Health; the phone doesn't export it unless the
    /// watch never confirms (`WatchHealthRules.phoneFallbackDelay`).
    public func acceptWatchClaim(_ workoutId: UUID) {
        let time = now()
        update { $0.watchClaims[workoutId.uuidString] = time }
    }

    public func isClaimedByWatch(_ workoutId: UUID) -> Bool { state.watchClaims[workoutId.uuidString] != nil }

    /// The workout was discarded: nothing for the watch to write.
    public func dropWatchClaim(_ workoutId: UUID) {
        guard isClaimedByWatch(workoutId) else { return }
        update { $0.watchClaims[workoutId.uuidString] = nil }
    }

    /// The watch wrote the Health workout. Taken whenever it arrives, and idempotent: with nothing written by the
    /// phone it's recorded by the watch for good; otherwise the next export run keeps the watch's copy once Health
    /// shows it (see the rules above). Run an export afterwards.
    public func markRecordedByWatch(_ workoutId: UUID) {
        let key = workoutId.uuidString
        switch state.workouts[key] {
        case WatchHealthRules.recordedByWatch?:
            return
        case nil:
            update {
                $0.workouts[key] = WatchHealthRules.recordedByWatch
                $0.watchClaims[key] = nil
                $0.watchAcks[key] = nil
            }
            failedWorkouts.remove(workoutId)
        default:
            Self.log.notice("Watch recorded a workout the phone exported: keeping the watch's copy once Health shows it")
            let time = now()
            update { $0.watchAcks[key] = $0.watchAcks[key] ?? time }
        }
    }

    /// The Apple Watch writes (or wrote, or may still write) this one: never a second copy from the phone. Looks in
    /// Health first when the watch's confirmation is overdue or came after the phone's export.
    func leftToWatch(_ workoutId: UUID, endedAt: Date, run: Int) async -> Bool {
        let key = workoutId.uuidString
        switch WatchHealthRules.phoneDecision(ledger: state.workouts[key], claimedAt: state.watchClaims[key],
                                              endedAt: endedAt, now: now()) {
        case .recordedByWatch:
            failedWorkouts.remove(workoutId)
            return true
        case .waitForWatch:
            return true
        case .export where state.watchAcks[key] == nil:
            return false
        case .exportUnlessWatchSaved where Self.isComplete(state.workouts[key]) && state.watchAcks[key] == nil:
            return false // the phone's fallback copy is in Health and the watch never said it saved one
        case .export, .exportUnlessWatchSaved:
            return await lookForWatchCopy(workoutId, run: run) != .notFound
        }
    }

    private enum WatchCopyLookup { case adopted, notFound, failed }

    /// Adopts the watch's copy when Health has one (removing the phone's own copy, if any); a failed lookup skips the
    /// workout this run (it's retried) rather than risk replacing the watch's copy.
    private func lookForWatchCopy(_ workoutId: UUID, run: Int) async -> WatchCopyLookup {
        let key = workoutId.uuidString
        do {
            let copies = try await store.workoutCopies(externalId: workoutId)
            guard run == generation else { return .failed }
            if state.workouts[key] == WatchHealthRules.recordedByWatch { return .adopted } // confirmed meanwhile
            guard copies.contains(where: { !$0.writtenByThisApp }) else {
                expireWatchAck(key)
                return .notFound
            }
            let previous = state.workouts[key]
            if previous != nil || copies.contains(where: \.writtenByThisApp) {
                let hadEnergy = Self.hadOptional(previous)
                update { $0.workouts[key] = Self.needsRetry(optional: "energy", hadEnergy) } // a delete can half-succeed
                try await store.deleteOwnWorkout(externalId: workoutId, withEnergy: hadEnergy)
                guard run == generation else { return .failed }
            }
            update {
                $0.workouts[key] = WatchHealthRules.recordedByWatch
                $0.watchClaims[key] = nil
                $0.watchAcks[key] = nil
            }
            failedWorkouts.remove(workoutId)
            return .adopted
        } catch {
            guard run == generation else { return .failed }
            Self.log.error("Looking for the watch's workout failed: \(error.localizedDescription, privacy: .public)")
            failedWorkouts.insert(workoutId)
            return .failed
        }
    }

    private func expireWatchAck(_ key: String) {
        guard let ack = state.watchAcks[key], now().timeIntervalSince(ack) > Self.watchAckWindow else { return }
        Self.log.notice("The watch's workout never showed up in Health: keeping the phone's copy")
        update {
            $0.watchAcks[key] = nil
            $0.watchClaims[key] = nil // done looking: later runs treat it as the phone's
        }
    }
}
