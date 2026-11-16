import Foundation

/// What the Health sync remembers between launches (UserDefaults, per device — Health is per device too).
public struct HealthSyncState: Codable, Sendable, Equatable {
    public var enabled = false
    /// When the owner last turned Health on: app workouts ending after this are exported.
    public var enabledAt: Date?
    /// Exported workouts: workout id → fingerprint of what Health has.
    public var workouts: [String: String] = [:]
    /// Exported weigh-ins: entry id → fingerprint.
    public var weighIns: [String: String] = [:]
    /// Anchored-query position for the body sample import, and the start date that query uses.
    public var anchor: Data?
    public var importStart: Date?
    public var lastImportAt: Date?
    /// Weigh-ins added by the most recent import that brought any.
    public var lastImportCount = 0
    /// Body fat samples that arrived before their weight (kept briefly so a later weight can pick them up).
    public var pendingBodyFat: [PendingBodyFat] = []
    /// Samples deleted in Health whose weigh-in wasn't on this iPhone at the time (e.g. signed out); applied when the
    /// weigh-in comes back from the cloud. Capped at `HealthSync.maxUnmatchedDeletions`, oldest dropped.
    public var unmatchedDeletions: [UUID] = []
    /// Whose data the export ledgers describe (account id, or "local"), and whether the local store was wiped and
    /// not yet restored: meanwhile a missing workout/weigh-in is not treated as deleted.
    public var ledgerOwner: String?
    public var awaitingRestore = false
    /// When the wipe happened: only a successful pull after it counts as restored.
    public var awaitingRestoreSince: Date?

    /// Workouts whose Health copy the Apple Watch claimed (plan 17): workout id → when the phone accepted the claim.
    /// Stored optional only so states saved before plan 17 still decode; use `watchClaims`.
    public var watchClaimsStorage: [String: Date]?

    public var watchClaims: [String: Date] {
        get { watchClaimsStorage ?? [:] }
        set { watchClaimsStorage = newValue.isEmpty ? nil : newValue }
    }

    /// The watch confirmed it saved a workout the phone had already (or may have) exported: workout id → when. The
    /// next export runs look for the watch's copy in Health and keep that one (`HealthSync.watchAckWindow`).
    /// Optional storage like `watchClaimsStorage`; use `watchAcks`.
    public var watchAcksStorage: [String: Date]?

    public var watchAcks: [String: Date] {
        get { watchAcksStorage ?? [:] }
        set { watchAcksStorage = newValue.isEmpty ? nil : newValue }
    }

    // Plan 39: reading activity from Health. Plain optionals, or optional storage like `watchClaimsStorage`, so a state
    // saved before plan 39 still decodes: a decode failure resets the whole state, turning Health off and dropping the
    // export ledgers.

    /// Anchored-query position for outside workouts, and the start date that query uses.
    public var activityAnchor: Data?
    public var activityImportStart: Date?
    /// When days of activity were last read: the next read starts 6 days before that day (the first reads 2 years).
    public var activityDaysReadAt: Date?
    /// Outside workouts deleted in Health whose row wasn't on this iPhone yet (e.g. signed out): applied when the row
    /// comes back from the cloud. Capped like `unmatchedDeletions`; use `unmatchedActivityDeletions`.
    public var unmatchedActivityDeletionsStorage: [UUID]?
    /// Settings › Apple Health › "Workouts from other apps" and "Steps & activity", on unless turned off.
    public var readsOutsideWorkoutsStorage: Bool?
    public var readsActivityDaysStorage: Bool?
    /// Health was asked for the activity types (by `enable()` or `allowActivity()`); nothing is read before.
    public var activityPermissionsAskedStorage: Bool?
    /// Today's one-time card was answered "Not now".
    public var activityCardDismissedStorage: Bool?

    public var unmatchedActivityDeletions: [UUID] {
        get { unmatchedActivityDeletionsStorage ?? [] }
        set { unmatchedActivityDeletionsStorage = newValue.isEmpty ? nil : newValue }
    }

    public var readsOutsideWorkouts: Bool {
        get { readsOutsideWorkoutsStorage ?? true }
        set { readsOutsideWorkoutsStorage = newValue ? nil : false }
    }

    public var readsActivityDays: Bool {
        get { readsActivityDaysStorage ?? true }
        set { readsActivityDaysStorage = newValue ? nil : false }
    }

    public var activityPermissionsAsked: Bool {
        get { activityPermissionsAskedStorage ?? false }
        set { activityPermissionsAskedStorage = newValue ? true : nil }
    }

    public var activityCardDismissed: Bool {
        get { activityCardDismissedStorage ?? false }
        set { activityCardDismissedStorage = newValue ? true : nil }
    }

    public init() {}

    public struct PendingBodyFat: Codable, Sendable, Equatable {
        public let uuid: UUID
        public let date: Date
        public let value: Double
    }

    static let key = "healthSync.state"

    static func load(from defaults: UserDefaults) -> HealthSyncState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(HealthSyncState.self, from: data) else { return HealthSyncState() }
        return state
    }

    func save(to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.key)
    }

    /// DEBUG `-healthBeforeActivity` (UI tests): what a build from before plan 39 saved with Health on, so Today
    /// offers the one-time activity card.
    public static func saveEnabledBeforeActivity(to defaults: UserDefaults, at date: Date) throws {
        var state = HealthSyncState()
        state.enabled = true
        state.enabledAt = date
        try state.save(to: defaults)
    }
}
