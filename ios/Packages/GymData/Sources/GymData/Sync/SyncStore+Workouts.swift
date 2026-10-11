import Foundation
import GymCore
import SwiftData

// Workouts: never the active one; dirty + remotely changed = conflict for the owner to resolve.
extension SyncStore {
    public func dirtyWorkouts() throws -> [SyncRow<WorkoutSnapshot>] {
        try context.fetch(FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.dirty && !$0.isActive },
                                                         sortBy: [SortDescriptor(\.startedAt)]))
            .map { SyncRow(value: try $0.snapshot(), clientUpdatedAt: $0.updatedAt, deletedAt: $0.deletedAt,
                           serverUpdatedAt: $0.serverUpdatedAt) }
    }

    /// Applies remote workouts and returns the ids that conflict: dirty locally and changed on the server since
    /// this device last saw it. Those local rows are left untouched.
    @discardableResult
    public func applyRemote(workouts rows: [SyncRow<WorkoutSnapshot>]) throws -> [UUID] {
        var conflicts: [UUID] = []
        for row in rows {
            let id = row.value.workout.id
            let existing = try workoutRecord(id)
            if let existing {
                if existing.isActive { continue }
                if existing.dirty {
                    if existing.serverUpdatedAt != row.serverUpdatedAt { conflicts.append(id) }
                    continue
                }
            } else if row.deletedAt != nil {
                continue
            }
            try write(row, into: existing)
        }
        try context.save()
        return conflicts
    }

    /// Resolves a conflict. Keeping local re-stamps the edit time to now so the next push wins; keeping the remote
    /// version replaces the local workout with it (clean). A nil `remote` leaves the local row dirty.
    public func resolveWorkoutConflict(id: UUID, keepLocal: Bool, remote: SyncRow<WorkoutSnapshot>?) throws {
        guard let r = try workoutRecord(id), !r.isActive else { return }
        if keepLocal {
            r.updatedAt = now()
            r.dirty = true
        } else if let remote, remote.value.workout.id == id {
            try write(remote, into: r)
        } else {
            return
        }
        try context.save()
    }

    private func write(_ row: SyncRow<WorkoutSnapshot>, into existing: WorkoutRecord?) throws {
        let w = row.value.workout
        let r = existing ?? {
            let new = WorkoutRecord(id: w.id, startedAt: w.startedAt, name: w.name, sourceRaw: w.source.rawValue,
                                    isActive: false, now: row.clientUpdatedAt)
            context.insert(new)
            return new
        }()
        r.startedAt = w.startedAt
        r.endedAt = w.endedAt
        r.pausedSeconds = w.pausedSeconds
        r.pausedAt = nil
        r.routineId = w.routineId
        r.name = w.name
        r.sourceRaw = w.source.rawValue
        r.note = w.note
        r.isActive = false
        r.volumeKg = row.value.volumeKg
        r.recordsData = row.value.records.isEmpty ? nil : try JSONEncoder().encode(row.value.records)
        r.deletedAt = row.deletedAt
        try r.setEntries(w.entries, in: context)
        markClean(r, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: row.serverUpdatedAt)
    }
}

extension WorkoutRecord {
    func snapshot() throws -> WorkoutSnapshot {
        let records = try recordsData.map { try JSONDecoder().decode([PersonalRecord].self, from: $0) } ?? []
        return WorkoutSnapshot(workout: value, records: records, volumeKg: volumeKg)
    }
}
