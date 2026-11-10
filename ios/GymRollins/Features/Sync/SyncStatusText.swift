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

/// One line of Account's refused rows: what they are, how many, and the server's words.
struct SyncFailureLine: Equatable, Identifiable {
    struct Key: Hashable {
        let entity: SyncEntity
        let message: String
    }

    let entity: SyncEntity
    let count: Int
    let message: String

    /// "Weigh-in", or "Weigh-in · 300" for more than one.
    var title: String {
        let name = SyncStatusText.entityName(entity)
        return count == 1 ? name : "\(name) \u{00B7} \(count)"
    }

    /// What VoiceOver reads for the line: "Weigh-in, <words>", or "300 weigh-ins, <words>".
    var spokenLabel: String {
        let what = count == 1 ? SyncStatusText.entityName(entity) : "\(count) \(SyncStatusText.entityPlural(entity))"
        return "\(what), \(message)"
    }

    var id: String { "\(entity.rawValue)\n\(message)" }
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

    /// The account caps' codes (server/src/sync/caps.ts, migrations/0010_account_caps.sql). Deleted rows count toward
    /// them (plan 31, decision 4), so a row refused at one is refused again however it is edited.
    static let accountCapCodes: Set<String> = [
        "too_many_workouts", "too_many_body_weights", "too_many_routines", "too_many_custom_exercises",
        "too_many_exercise_prefs", "too_many_gyms_total", "too_many_listings_total", "too_many_logged_exercises",
        "too_many_logged_sets",
    ]

    /// Under the refused rows: they stay on this phone, and an edit sends one again, unless every one was refused at
    /// an account cap, where an edit is refused again.
    static func failuresFooter(_ failures: [SyncFailure]) -> String {
        let capped = !failures.isEmpty && failures.allSatisfy { $0.code.map(accountCapCodes.contains) ?? false }
        return capped ? "They stay on this iPhone." : "They stay on this iPhone. Editing one tries again."
    }

    /// Account's refused rows, one line per kind of row and reason, in the store's order. At an account limit every
    /// refused row has the same words, so 300 weigh-ins past it read as one line, not 300.
    static func failureLines(_ failures: [SyncFailure]) -> [SyncFailureLine] {
        let keys = failures.map { SyncFailureLine.Key(entity: $0.entity, message: $0.message) }
        let counts = Dictionary(keys.map { ($0, 1) }, uniquingKeysWith: +)
        var seen = Set<SyncFailureLine.Key>()
        return keys.filter { seen.insert($0).inserted }.map { key in
            SyncFailureLine(entity: key.entity, count: counts[key, default: 1], message: key.message)
        }
    }

    static func entityName(_ entity: SyncEntity) -> String {
        switch entity {
        case .profile: "Profile"
        case .customExercises: "Custom exercise"
        case .exercisePreferences: "Exercise preference"
        case .routines: "Routine"
        case .weekSchedule: "Week schedule"
        case .muscleTargets: "Weekly target"
        case .gyms: "Gym"
        case .gymListings: "Equipment"
        case .bodyweight: "Weigh-in"
        case .workouts: "Workout"
        case .proposals: "Claude proposal"
        }
    }

    /// `entityName`'s plural, as VoiceOver reads a count of them ("300 weigh-ins").
    static func entityPlural(_ entity: SyncEntity) -> String {
        switch entity {
        case .profile: "profiles"
        case .customExercises: "custom exercises"
        case .exercisePreferences: "exercise preferences"
        case .routines: "routines"
        case .weekSchedule: "week schedule days"
        case .muscleTargets: "weekly targets"
        case .gyms: "gyms"
        case .gymListings: "equipment listings"
        case .bodyweight: "weigh-ins"
        case .workouts: "workouts"
        case .proposals: "Claude proposals"
        }
    }

    private static func pendingText(_ pending: Int) -> String {
        pending == 1 ? "1 change waiting to sync" : "\(pending) changes waiting to sync"
    }
}
