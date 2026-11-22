import Foundation
import GymCore
import SwiftData

// What Apple Health measured during GymRollins workouts (plan 40). The phone that read Health writes a row; a pulled
// row replaces the local one by plain last-write-wins. Rows go with their workout: workouts are pulled first, and a
// pulled row whose workout is missing or deleted here is skipped (deleted here or elsewhere, so the server's
// copy is never read), as is one this app can't store. A pulled deletion removes the local row.
extension SyncStore {
    public func dirtyWorkoutMeasurements() throws -> [SyncRow<MeasurementSnapshot>] {
        try context.fetch(FetchDescriptor<MeasurementRecord>(predicate: #Predicate { $0.dirty },
                                                             sortBy: [SortDescriptor(\.updatedAt)]))
            .map { SyncRow(value: $0.value, clientUpdatedAt: $0.updatedAt, serverUpdatedAt: $0.serverUpdatedAt) }
    }

    /// The dirty rows whose workout the server already holds (clean, with a server stamp). A row sent before its
    /// workout is refused and then blocked until its numbers change, so it waits instead.
    public func pushableWorkoutMeasurements() throws -> [SyncRow<MeasurementSnapshot>] {
        let rows = try dirtyWorkoutMeasurements()
        var held = Set<UUID>()
        for batch in IdBatches.of(rows.map(\.value.workoutId)) {
            var d = FetchDescriptor<WorkoutRecord>(predicate: #Predicate {
                batch.contains($0.id) && !$0.dirty && $0.serverUpdatedAt != nil
            })
            d.propertiesToFetch = [\.id]
            held.formUnion(try context.fetch(d).map(\.id))
        }
        return rows.filter { held.contains($0.value.workoutId) }
    }

    public func applyRemote(workoutMeasurements rows: [SyncRow<MeasurementSnapshot>]) throws {
        let ids = rows.map(\.value.workoutId)
        let live = try liveWorkoutIds(among: ids)
        var stored = try measurementRecords(ids)
        for row in rows where row.value.isValid {
            let id = row.value.workoutId
            let existing = stored[id]
            if let existing, !remoteWins(over: existing, remoteEdit: row.clientUpdatedAt) { continue }
            guard row.deletedAt == nil, live.contains(id) else {
                if let existing { context.delete(existing) }
                stored[id] = nil
                continue
            }
            let r = existing ?? {
                let new = MeasurementRecord(row.value)
                context.insert(new)
                stored[id] = new
                return new
            }()
            r.apply(row.value)
            markClean(r, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: row.serverUpdatedAt)
        }
        try context.save()
    }

    func measurementRecord(_ workoutId: UUID) throws -> MeasurementRecord? {
        try MeasurementRecord.of(workoutId, in: context)
    }

    /// The rows of these workouts, by workout id (`IdBatches.size` ids a fetch).
    private func measurementRecords(_ ids: [UUID]) throws -> [UUID: MeasurementRecord] {
        var found: [UUID: MeasurementRecord] = [:]
        for batch in IdBatches.of(ids) {
            let d = FetchDescriptor<MeasurementRecord>(predicate: #Predicate { batch.contains($0.workoutId) })
            for r in try context.fetch(d) { found[r.workoutId] = r }
        }
        return found
    }

    /// The ids among `ids` of workouts on this phone that aren't deleted, finished or not: the cursor moves past a
    /// pulled row, so one skipped for a workout still running would never come back.
    private func liveWorkoutIds(among ids: [UUID]) throws -> Set<UUID> {
        var found = Set<UUID>()
        for batch in IdBatches.of(ids) {
            var d = FetchDescriptor<WorkoutRecord>(predicate: #Predicate {
                batch.contains($0.id) && $0.deletedAt == nil
            })
            d.propertiesToFetch = [\.id]
            found.formUnion(try context.fetch(d).map(\.id))
        }
        return found
    }
}
