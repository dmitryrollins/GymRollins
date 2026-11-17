import Foundation
import GymCore

/// One row of the Log's history (plan 39): a GymRollins workout or an outside workout from Apple Health.
enum LogItem: Identifiable, Equatable {
    case workout(Workout)
    case outside(HealthActivity)

    var id: UUID {
        switch self {
        case .workout(let workout): workout.id
        case .outside(let activity): activity.id
        }
    }

    var startedAt: Date {
        switch self {
        case .workout(let workout): workout.startedAt
        case .outside(let activity): activity.startedAt
        }
    }
}

/// GymRollins workouts and outside workouts in one history, newest first.
enum LogTimeline {
    /// `workouts` is a page, newest first. While more may follow (`complete` false), an outside workout older than the
    /// page's last workout waits for the next page, so the list doesn't reshuffle when a page loads.
    static func merge(workouts: [Workout], outside: [HealthActivity], complete: Bool) -> [LogItem] {
        let oldest = complete ? nil : workouts.last?.startedAt
        let shown = outside.filter { activity in oldest.map { activity.startedAt >= $0 } ?? true }
        return (workouts.map(LogItem.workout) + shown.map(LogItem.outside)).sorted { a, b in
            a.startedAt != b.startedAt ? a.startedAt > b.startedAt : a.id.uuidString < b.id.uuidString
        }
    }
}
