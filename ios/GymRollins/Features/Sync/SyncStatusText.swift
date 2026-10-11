import Foundation
import GymData
import GymSync

/// What the sync banner on Today/Log shows for a status; nil hides it (idle and syncing are quiet).
struct SyncBannerState: Equatable {
    enum Kind: Equatable { case offline, error, conflicts }

    let kind: Kind
    let text: String
    /// Whether tapping opens the conflict review.
    var reviewable: Bool { kind == .conflicts }

    static func make(_ status: SyncStatus) -> SyncBannerState? {
        switch status {
        case .idle, .syncing:
            return nil
        case .offline:
            return SyncBannerState(kind: .offline, text: "Offline \u{00B7} changes saved on this iPhone")
        case .error:
            return SyncBannerState(kind: .error, text: "Couldn't sync \u{00B7} your data is safe on this iPhone")
        case .conflicts(let ids):
            let noun = ids.count == 1 ? "1 workout" : "\(ids.count) workouts"
            return SyncBannerState(kind: .conflicts, text: "\(noun) changed on another device \u{00B7} Review")
        }
    }
}

/// Account-screen wording for sync state.
enum SyncStatusText {
    /// "Just now", "2 min ago", "3 h ago", or a date; "Never" before the first sync.
    static func lastSynced(_ date: Date?, now: Date) -> String {
        guard let date else { return "Never" }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "Just now"
        case ..<3_600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3_600)) h ago"
        default: return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        }
    }

    static func status(_ status: SyncStatus, pending: Int, lastSyncedAt: Date?) -> String {
        switch status {
        case .syncing: return "Syncing\u{2026}"
        case .offline: return pending == 0 ? "Offline" : "Offline \u{00B7} \(pendingText(pending))"
        case .error(let message): return message
        case .conflicts(let ids): return ids.count == 1 ? "1 workout needs review" : "\(ids.count) workouts need review"
        case .idle:
            if lastSyncedAt == nil { return "Not synced yet" }
            return pending == 0 ? "Up to date" : pendingText(pending)
        }
    }

    /// "1 item couldn't sync" / "3 items couldn't sync".
    static func failures(_ count: Int) -> String {
        count == 1 ? "1 item couldn't sync" : "\(count) items couldn't sync"
    }

    static func entityName(_ entity: SyncEntity) -> String {
        switch entity {
        case .profile: "Profile"
        case .customExercises: "Custom exercise"
        case .exercisePreferences: "Exercise preference"
        case .routines: "Routine"
        case .weekSchedule: "Week schedule"
        case .muscleTargets: "Weekly target"
        case .bodyweight: "Weigh-in"
        case .workouts: "Workout"
        case .proposals: "Claude proposal"
        }
    }

    private static func pendingText(_ pending: Int) -> String {
        pending == 1 ? "1 change waiting to sync" : "\(pending) changes waiting to sync"
    }
}
