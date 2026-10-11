import Foundation
import GymCore
import SwiftData

@MainActor
public final class WorkoutRepository {
    let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    /// Finished, non-deleted workouts, newest first.
    public func recent(limit: Int) throws -> [Workout] {
        var d = FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.deletedAt == nil && !$0.isActive },
                                               sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        d.fetchLimit = limit
        return try context.fetch(d).map(\.value)
    }

    /// Finished, non-deleted workouts that ended at or after `date`, oldest first (Apple Health export candidates).
    public func finished(endedSince date: Date) throws -> [Workout] {
        let d = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.deletedAt == nil && !$0.isActive && $0.endedAt != nil },
            sortBy: [SortDescriptor(\.startedAt)])
        return try context.fetch(d).filter { ($0.endedAt ?? .distantPast) >= date }.map(\.value)
    }

    /// True when this workout was deleted (a tombstone exists), as opposed to never having been on this device.
    public func isDeleted(_ id: UUID) throws -> Bool {
        try record(id)?.deletedAt != nil
    }

    public func workout(_ id: UUID) throws -> Workout? {
        try record(id).flatMap { $0.deletedAt == nil ? $0.value : nil }
    }

    /// Progression data points for one exercise, newest first.
    ///
    /// Fetches only the `WorkoutEntryRecord`s for this exercise (rather than every finished
    /// workout), so cost scales with how often the exercise was performed instead of with total
    /// workout history.
    public func history(exerciseId: String, limit: Int) throws -> [SessionResult] {
        try finishedEntries(exerciseId: exerciseId)
            .lazy
            .compactMap { SessionHistory.result(for: $0.entry, date: $0.date) }
            .prefix(limit)
            .map { $0 }
    }

    /// Whole entries (every set) for one exercise from finished workouts, newest first, with the
    /// workout's start date. Used for set-level trends such as e1RM and best set.
    public func sessions(exerciseId: String, limit: Int) throws -> [(date: Date, entry: WorkoutEntry)] {
        Array(try finishedEntries(exerciseId: exerciseId).prefix(limit))
    }

    /// All-time bests for PR detection, or nil if never performed.
    public func bests(exerciseId: String) throws -> ExerciseBests? {
        let entries = try finishedEntries(exerciseId: exerciseId)
        guard !entries.isEmpty else { return nil }
        return entries.map { ExerciseBests(entry: $0.entry) }.reduce(ExerciseBests(e1RMKg: nil, repsAtWeight: [:], volumeKg: 0)) { $0.merging($1) }
    }

    /// Saves a finished workout (insert or replace), computing volume.
    ///
    /// `records` is JSON-encoded onto the row when non-empty. An empty (default) list leaves the
    /// existing `recordsData` untouched, so re-saving a workout later (e.g. an edit) never erases
    /// records computed at finish time.
    public func save(_ workout: Workout, records: [PersonalRecord] = []) throws {
        let r = try upsertRecord(workout, isActive: false)
        r.pausedAt = nil
        r.volumeKg = WorkoutMetrics.volumeKg(workout)
        if !records.isEmpty {
            r.recordsData = try JSONEncoder().encode(records)
        }
        try context.save()
    }

    /// The personal records persisted with a workout, or `[]` if none.
    public func records(for id: UUID) throws -> [PersonalRecord] {
        guard let data = try record(id)?.recordsData else { return [] }
        return try JSONDecoder().decode([PersonalRecord].self, from: data)
    }

    /// Number of persisted records per workout id, omitting ids with none.
    public func recordCounts(ids: [UUID]) throws -> [UUID: Int] {
        let idSet = Set(ids)
        let descriptor = FetchDescriptor<WorkoutRecord>(predicate: #Predicate { idSet.contains($0.id) })
        return try context.fetch(descriptor).reduce(into: [:]) { counts, r in
            guard let data = r.recordsData else { return }
            let decoded = try JSONDecoder().decode([PersonalRecord].self, from: data)
            if !decoded.isEmpty { counts[r.id] = decoded.count }
        }
    }

    /// Persists the in-progress workout after every change (resume after app kill).
    ///
    /// At most one workout may be active at a time. If another record with a different id is
    /// already active, it is discarded first: an active workout is never synced, so it was only
    /// ever a local, in-progress session, and the caller starting a new one means the previous
    /// session was abandoned (e.g. after a force-quit) rather than something to preserve.
    public func saveActive(_ workout: Workout, pausedAt: Date?) throws {
        if let stale = try activeRecord(), stale.id != workout.id {
            context.delete(stale)
        }
        let r = try upsertRecord(workout, isActive: true)
        r.pausedAt = pausedAt
        try context.save()
    }

    public func active() throws -> (Workout)? {
        try activeRecord()?.value
    }

    public func activeClock() throws -> WorkoutClock? {
        try activeRecord()?.clock
    }

    public func discardActive() throws {
        if let r = try activeRecord() { context.delete(r); try context.save() }
    }

    public func delete(_ id: UUID) throws {
        guard let r = try record(id) else { return }
        r.deletedAt = now()
        r.updatedAt = now()
        r.dirty = true
        try context.save()
    }

    // MARK: - Private

    /// This exercise's entries from finished, non-deleted workouts, newest workout first (position order within a
    /// workout). The filter and sort run in SQL on the workout rows and entries come from their `entriesData` cache,
    /// so no entry/set rows are materialized (see `WorkoutRecord.entriesData`).
    private func finishedEntries(exerciseId: String) throws -> [(date: Date, entry: WorkoutEntry)] {
        let descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { workout in
                workout.deletedAt == nil && !workout.isActive
                    && workout.entries.contains { $0.exerciseId == exerciseId }
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        // One session per workout: entries of the same exercise within a workout (e.g. the exercise in two
        // supersets) are merged, so progression never sees them as separate, shorter sessions.
        return try context.fetch(descriptor).compactMap { workout in
            let entries = workout.entryValues.filter { $0.exerciseId == exerciseId }
            guard let first = entries.first else { return nil }
            let merged = entries.count == 1 ? first
                : WorkoutEntry(id: first.id, exerciseId: exerciseId, sets: entries.flatMap(\.sets), note: first.note,
                               supersetGroup: first.supersetGroup)
            return (date: workout.startedAt, entry: merged)
        }
    }

    private func record(_ id: UUID) throws -> WorkoutRecord? {
        try context.fetch(FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func activeRecord() throws -> WorkoutRecord? {
        try context.fetch(FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.isActive })).first
    }

    private func upsertRecord(_ w: Workout, isActive: Bool) throws -> WorkoutRecord {
        let r = try record(w.id) ?? {
            let new = WorkoutRecord(id: w.id, startedAt: w.startedAt, name: w.name, sourceRaw: w.source.rawValue,
                                    isActive: isActive, now: now())
            context.insert(new)
            return new
        }()
        r.startedAt = w.startedAt
        r.endedAt = w.endedAt
        r.pausedSeconds = w.pausedSeconds
        r.routineId = w.routineId
        r.name = w.name
        r.sourceRaw = w.source.rawValue
        r.note = w.note
        r.isActive = isActive
        r.deletedAt = nil
        try r.setEntries(w.entries, in: context)
        r.updatedAt = now()
        r.dirty = !isActive
        return r
    }
}
