import Foundation

/// Exactly one Apple Health workout per GymRollins workout (plan 17).
///
/// The watch's workout session claims the running workout (`healthClaim`); the phone accepts only while that workout
/// is running and Health is on. Then the watch — which has heart rate and measured energy — writes the Health workout
/// and the phone's exporter leaves it alone. Without an accepted claim the phone exports as before and the watch
/// discards its session. If the watch's confirmation hasn't arrived after `phoneFallbackDelay`, the phone first looks in
/// Health for the watch's copy (watch samples sync to the phone's Health store, and a queued confirmation can arrive
/// late): found, it's recorded by the watch; only when there's none does the phone export its estimate. A confirmation
/// arriving after the phone exported keeps one copy, the watch's measured one (see `HealthSync+Watch`).
public enum WatchHealthRules {
    /// After this long past the workout's end without the watch's confirmation, the phone exports it itself.
    public static let phoneFallbackDelay: TimeInterval = 2 * 3_600
    /// The watch only saves its workout within this long after the phone workout was finished.
    public static let watchSaveWindow: TimeInterval = 3_600
    /// The phone's export-ledger value for a workout the watch wrote to Health.
    public static let recordedByWatch = "watch"

    /// Metadata shared with the phone's `HealthKitStore` export: the same keys and sync identifier, so HealthKit also
    /// treats the two as one workout.
    public static let workoutNameKey = "GymRollinsWorkoutName"
    public static let exportMarkerKey = "GymRollinsExport"
    /// Who wrote a GymRollins workout to Health. A companion watch app's samples may carry the iOS app's HealthKit
    /// source, so the source can't tell the watch's measured copy from the phone's estimate; this metadata can.
    public static let writerKey = "GymRollinsWriter"
    public static let watchWriter = "watch"
    public static let phoneWriter = "phone"

    /// Whether a GymRollins workout in Health is the watch's recording: its writer metadata, or — for a copy saved
    /// before that key existed — the device that recorded it.
    public static func isWatchRecording(writer: String?, deviceModel: String?) -> Bool {
        if let writer { return writer == watchWriter }
        return deviceModel == "Watch"
    }

    public static func syncIdentifier(workoutId: UUID) -> String { "gymrollins.workout.\(workoutId.uuidString)" }

    public enum PhoneDecision: Equatable, Sendable {
        /// The phone writes (or updates) the Health workout.
        case export
        /// The watch wrote it: done, never touched by the phone's exporter.
        case recordedByWatch
        /// The watch claimed it and hasn't confirmed yet: skip for now.
        case waitForWatch
        /// The watch claimed it and its confirmation is overdue: look in Health for the watch's copy first; recorded by
        /// the watch when it's there, otherwise the phone writes it.
        case exportUnlessWatchSaved
    }

    public static func phoneDecision(ledger: String?, claimedAt: Date?, endedAt: Date, now: Date) -> PhoneDecision {
        if ledger == recordedByWatch { return .recordedByWatch }
        guard claimedAt != nil else { return .export }
        return now.timeIntervalSince(endedAt) < phoneFallbackDelay ? .waitForWatch : .exportUnlessWatchSaved
    }

    public static func phoneAcceptsClaim(workoutId: UUID, runningWorkoutId: UUID?, healthEnabled: Bool) -> Bool {
        healthEnabled && runningWorkoutId == workoutId
    }

    /// Whether the watch saves its session for `workoutId` now that the phone workout ended as `ended`.
    public static func watchShouldSave(workoutId: UUID, ended: WatchEndedWorkout?, now: Date) -> Bool {
        guard let ended, ended.workoutId == workoutId, ended.finished, ended.watchRecordsHealth else { return false }
        return now.timeIntervalSince(ended.finishedAt ?? ended.endedAt) <= watchSaveWindow
    }
}
