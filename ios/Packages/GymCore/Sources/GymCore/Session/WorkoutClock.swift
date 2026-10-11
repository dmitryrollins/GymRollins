import Foundation

/// Elapsed workout time with pauses. Immutable: pausing/resuming return new clocks.
public struct WorkoutClock: Codable, Sendable, Equatable {
    public let startedAt: Date
    public let pausedAt: Date?
    public let pausedSeconds: TimeInterval

    public init(startedAt: Date, pausedAt: Date? = nil, pausedSeconds: TimeInterval = 0) {
        self.startedAt = startedAt
        self.pausedAt = pausedAt
        self.pausedSeconds = pausedSeconds
    }

    public var isPaused: Bool { pausedAt != nil }

    public func elapsed(at now: Date) -> TimeInterval {
        let end = pausedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - pausedSeconds)
    }

    /// Paused seconds of a workout that ends at `end`. An open pause counts up to `end` (finishing now = resuming
    /// first); one that began after `end` doesn't count at all. Only the total of the earlier pauses is known, not
    /// when they were, so they're taken to fall before `end`, capped at the time since start (duration ≥ 0).
    public func pausedSeconds(endingAt end: Date) -> TimeInterval {
        if let pausedAt, end >= pausedAt { return pausedSeconds + end.timeIntervalSince(pausedAt) }
        return min(pausedSeconds, max(0, end.timeIntervalSince(startedAt)))
    }

    /// The workout's duration if it ends at `end`: end − start − paused, never negative.
    public func duration(endingAt end: Date) -> TimeInterval {
        max(0, end.timeIntervalSince(startedAt) - pausedSeconds(endingAt: end))
    }

    public func pausing(at now: Date) -> WorkoutClock {
        guard !isPaused else { return self }
        return WorkoutClock(startedAt: startedAt, pausedAt: now, pausedSeconds: pausedSeconds)
    }

    public func resuming(at now: Date) -> WorkoutClock {
        guard let pausedAt else { return self }
        return WorkoutClock(startedAt: startedAt, pausedAt: nil,
                            pausedSeconds: pausedSeconds + max(0, now.timeIntervalSince(pausedAt)))
    }
}

public enum DurationFormatter {
    /// "24:12", "1:05:57", "0:05".
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3_600, (total % 3_600) / 60, total % 60)
        return h > 0
            ? String(format: "%ld:%02ld:%02ld", h, m, s)
            : String(format: "%ld:%02ld", m, s)
    }

    /// Whole minutes: "65m".
    public static func minutes(_ seconds: TimeInterval) -> String {
        "\(max(0, Int(seconds)) / 60)m"
    }

    /// Spoken-style hours and whole minutes: "1 h 27 min", "2 h", "45 min".
    public static func hoursMinutes(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds)) / 60
        let (h, m) = (minutes / 60, minutes % 60)
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) h"
        default: return "\(h) h \(m) min"
        }
    }
}
