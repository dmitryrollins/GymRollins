import Foundation
import GymCore
import SwiftData

// Queries for the insights (recovery, weekly sets, streaks).
extension WorkoutRepository {
    /// Finished, non-deleted workouts that started at or after `since`, newest first.
    public func finished(since: Date) throws -> [Workout] {
        let d = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.deletedAt == nil && !$0.isActive && $0.startedAt >= since },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return try context.fetch(d).map(\.value)
    }

    /// Start times of every finished, non-deleted workout (for streaks; entries aren't read).
    public func finishedStartDates() throws -> [Date] {
        var d = FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.deletedAt == nil && !$0.isActive })
        d.propertiesToFetch = [\.startedAt]
        return try context.fetch(d).map(\.startedAt)
    }

    /// How many finished, non-deleted workouts there are (a cheap check that the history gained or lost one).
    public func finishedCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.deletedAt == nil && !$0.isActive }))
    }

    /// The spans of finished, non-deleted workouts that started at or after `since` (all when nil), for attaching
    /// outside workouts to them (plan 39, rule 6). Entries aren't read.
    public func finishedSpans(since: Date?) throws -> [WorkoutSpan] {
        let start = since ?? .distantPast
        var d = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.deletedAt == nil && !$0.isActive && $0.startedAt >= start })
        d.propertiesToFetch = [\.id, \.startedAt, \.endedAt]
        return try context.fetch(d).compactMap { r in
            r.endedAt.map { WorkoutSpan(id: r.id, start: r.startedAt, end: $0) }
        }
    }
}
