import Foundation
import GymCore
import SwiftData

/// What Apple Health measured during GymRollins workouts (plan 40), one snapshot per workout: the numbers that sync
/// and that agents read. The app saves one after it reads Health; Health stays the source of the heart-rate readings.
@MainActor
public final class MeasurementRepository {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// The saved numbers of this workout, or nil.
    public func snapshot(for workoutId: UUID) throws -> MeasurementSnapshot? {
        try MeasurementRecord.of(workoutId, in: context)?.value
    }

    /// Saves the numbers and marks the row for sync; says whether it wrote. False when the stored row has the same
    /// numbers (a re-read that changed nothing), and when the workout isn't a finished, live workout on this phone
    /// (deleted while Health was read, or still running): the server takes a row only for a workout it holds. The
    /// edit time is the snapshot's, never earlier than the stored row's (sync's last write wins compares them).
    /// Throws for numbers outside `MeasurementLimits`.
    @discardableResult
    public func save(_ snapshot: MeasurementSnapshot) throws -> Bool {
        guard snapshot.isValid else { throw GymDataError.invalidInput("Measured numbers are out of range.") }
        guard try isFinished(snapshot.workoutId) else { return false }
        guard let r = try MeasurementRecord.of(snapshot.workoutId, in: context) else {
            context.insert(MeasurementRecord(snapshot))
            try context.save()
            return true
        }
        guard !r.value.sameNumbers(as: snapshot) else { return false }
        r.apply(snapshot)
        r.updatedAt = max(snapshot.clientUpdatedAt, r.updatedAt.addingTimeInterval(0.001))
        r.dirty = true
        try context.save()
        return true
    }

    /// Finished, live workouts that started on or after `date`, newest first: the ones the 90-day backfill reads
    /// Health for. Entries aren't read.
    public func finishedWorkoutIds(since date: Date) throws -> [UUID] {
        var d = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.deletedAt == nil && !$0.isActive && $0.endedAt != nil && $0.startedAt >= date },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        d.propertiesToFetch = [\.id]
        return try context.fetch(d).map(\.id)
    }

    private func isFinished(_ workoutId: UUID) throws -> Bool {
        let d = FetchDescriptor<WorkoutRecord>(predicate: #Predicate {
            $0.id == workoutId && $0.deletedAt == nil && !$0.isActive && $0.endedAt != nil
        })
        return try context.fetchCount(d) > 0
    }
}
