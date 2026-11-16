import Foundation

/// A finished GymRollins workout's time span, for rule 6.
public struct WorkoutSpan: Sendable, Equatable {
    public let id: UUID
    public let start: Date
    public let end: Date

    public init(id: UUID, start: Date, end: Date) {
        self.id = id
        self.start = start
        self.end = end
    }
}

/// Outside workouts after rules 6 and 7 (plan 39, decisions 6–8). Computed when read and never stored: an attachment
/// can appear later (a GymRollins workout logged afterwards, an agent's `log_workout`).
public struct ResolvedActivities: Sendable, Equatable {
    /// Shown and counted on their own: not attached, one per session; newest first.
    public let shown: [HealthActivity]
    /// Attached to a GymRollins workout (the same session, measured); newest first.
    public let attached: [HealthActivity]
    /// Attached outside workout id → its GymRollins workout id.
    public let attachedTo: [UUID: UUID]

    public static let none = ResolvedActivities(shown: [], attached: [], attachedTo: [:])

    public init(shown: [HealthActivity], attached: [HealthActivity], attachedTo: [UUID: UUID]) {
        self.shown = shown
        self.attached = attached
        self.attachedTo = attachedTo
    }

    /// The ones that count toward the streak and the weekly goal (decision 5): shown, 10 minutes or more.
    public var counted: [HealthActivity] { shown.filter(\.countsAsWorkout) }

    /// The outside workouts attached to this GymRollins workout.
    public func attached(to workoutId: UUID) -> [HealthActivity] {
        attached.filter { attachedTo[$0.id] == workoutId }
    }

    /// What this GymRollins workout shows as measured: the Apple Watch's recording first, else the longest.
    public func measured(for workoutId: UUID) -> HealthActivity? {
        attached(to: workoutId).sorted(by: ActivityRules.preferred).first
    }
}

/// Rules 6 and 7 (plan 39): one pure function, mirrored by `server/src/shared/activity.ts` and run by both on the
/// shared fixture `fixtures/activity.json`. Keep the two in step by hand.
/// - Rule 6: an outside workout overlapping a GymRollins workout by at least half of the shorter of the two is
///   attached to it (the largest overlap wins).
/// - Rule 7: of the rest, two of the same kind overlapping by 80 % or more of the shorter are one session, shown
///   once: the Apple Watch's recording first, else the longer.
public enum ActivityRules {
    public static let attachShare = 0.5
    public static let sameSessionShare = 0.8

    public static func resolve(_ activities: [HealthActivity], workouts: [WorkoutSpan]) -> ResolvedActivities {
        var attachedTo: [UUID: UUID] = [:]
        var free: [HealthActivity] = []
        for activity in activities {
            if let workout = workout(for: activity, in: workouts) {
                attachedTo[activity.id] = workout.id
            } else {
                free.append(activity)
            }
        }
        var kept: [HealthActivity] = []
        for activity in free.sorted(by: preferred) where !kept.contains(where: { sameSession($0, activity) }) {
            kept.append(activity)
        }
        return ResolvedActivities(shown: kept.sorted(by: newestFirst),
                                  attached: activities.filter { attachedTo[$0.id] != nil }.sorted(by: newestFirst),
                                  attachedTo: attachedTo)
    }

    /// The copy kept of one session: the Apple Watch's, then the longer (active time), then the earlier start, then
    /// the lower id.
    public static func preferred(_ a: HealthActivity, _ b: HealthActivity) -> Bool {
        if a.fromWatch != b.fromWatch { return a.fromWatch }
        if a.durationS != b.durationS { return a.durationS > b.durationS }
        if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
        return key(a.id) < key(b.id)
    }

    /// Rule 6's workout: the largest overlap reaching `attachShare` of the shorter, then the earlier start, then the
    /// lower id.
    static func workout(for activity: HealthActivity, in workouts: [WorkoutSpan]) -> WorkoutSpan? {
        let candidates = workouts.compactMap { span -> (span: WorkoutSpan, shared: TimeInterval)? in
            let shared = overlap(activity.startedAt, activity.endedAt, span.start, span.end)
            let shorter = min(length(activity.startedAt, activity.endedAt), length(span.start, span.end))
            return shared > 0 && shared >= attachShare * shorter ? (span, shared) : nil
        }
        return candidates.min { a, b in
            if a.shared != b.shared { return a.shared > b.shared }
            if a.span.start != b.span.start { return a.span.start < b.span.start }
            return key(a.span.id) < key(b.span.id)
        }?.span
    }

    static func sameSession(_ a: HealthActivity, _ b: HealthActivity) -> Bool {
        guard a.kind == b.kind else { return false }
        let shared = overlap(a.startedAt, a.endedAt, b.startedAt, b.endedAt)
        let shorter = min(length(a.startedAt, a.endedAt), length(b.startedAt, b.endedAt))
        return shared > 0 && shared >= sameSessionShare * shorter
    }

    /// Seconds two spans share.
    static func overlap(_ aStart: Date, _ aEnd: Date, _ bStart: Date, _ bEnd: Date) -> TimeInterval {
        max(0, min(aEnd, bEnd).timeIntervalSince(max(aStart, bStart)))
    }

    private static func length(_ start: Date, _ end: Date) -> TimeInterval { max(0, end.timeIntervalSince(start)) }

    private static func newestFirst(_ a: HealthActivity, _ b: HealthActivity) -> Bool {
        if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
        return key(a.id) < key(b.id)
    }

    /// Ids compare as the server stores them: lowercase.
    private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }
}
