import Foundation

/// The training week: Monday–Sunday in a calendar's time zone (the Log tab's week strip uses the same weeks).
public enum TrainingWeek {
    /// ISO 8601 calendar (Monday first) in `timeZone`.
    public static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The Monday 00:00 … next Monday 00:00 interval containing `date` (DST weeks are 167 or 169 hours).
    public static func interval(containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 7 * 86_400)
    }
}

public enum TargetStatus: String, Sendable, Codable {
    case below, within, above
}

public struct WeeklyMuscleSets: Equatable, Sendable, Identifiable {
    public var id: MuscleGroup { group }
    public let group: MuscleGroup
    /// Hard sets this week (primary 1, secondary 0.5).
    public let sets: Double
    public let target: SetTargetRange

    public init(group: MuscleGroup, sets: Double, target: SetTargetRange) {
        self.group = group
        self.sets = sets
        self.target = target
    }

    /// Compared at the precision shown (one decimal), so fractional contributions that add up to 9.999… count as
    /// the 10 displayed (the MCP port rounds the same way).
    public var status: TargetStatus {
        let shown = (sets * 10).rounded() / 10
        if shown < Double(target.min) { return .below }
        return shown > Double(target.max) ? .above : .within
    }

    /// Bar fill: sets as a share of the top of the range, 0…1 (a 0 target counts as full).
    public var fraction: Double {
        guard target.max > 0 else { return 1 }
        return min(1, sets / Double(target.max))
    }
}

/// Hard sets per muscle group in a week, and how they compare with the targets.
public enum WeeklySets {
    /// Workouts belong to the week their `startedAt` falls in.
    public static func count(workouts: [Workout], exercise: (String) -> Exercise?,
                             week: DateInterval) -> [MuscleGroup: Double] {
        var out: [MuscleGroup: Double] = [:]
        for workout in workouts where workout.startedAt >= week.start && workout.startedAt < week.end {
            for (group, load) in MuscleLoads.of(workout, exercise: exercise) {
                out[group, default: 0] += load.sets
            }
        }
        return out
    }

    /// Every group in declaration order; groups without a stored target use their default.
    public static func progress(counts: [MuscleGroup: Double],
                                targets: [MuscleGroup: SetTargetRange]) -> [WeeklyMuscleSets] {
        MuscleGroup.allCases.map { group in
            WeeklyMuscleSets(group: group, sets: counts[group] ?? 0, target: targets[group] ?? group.defaultTarget)
        }
    }

    /// "12", "3.5" — at most one decimal.
    public static func format(_ sets: Double) -> String {
        let tenths = (sets * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }
}
