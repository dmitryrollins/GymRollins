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
}
