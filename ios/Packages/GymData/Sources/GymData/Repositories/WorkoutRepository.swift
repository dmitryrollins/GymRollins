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

    /// The ids among `ids` that have a workout on this iPhone, live, running or deleted (a tombstone): what
    /// `workout(_:)` and `isDeleted(_:)` tell together, for a whole batch in one fetch (per `IdBatches.size` ids).
    public func recordedIds(among ids: Set<UUID>) throws -> Set<UUID> {
        var found = Set<UUID>()
        for batch in IdBatches.of(ids) {
            var d = FetchDescriptor<WorkoutRecord>(predicate: #Predicate { batch.contains($0.id) })
            d.propertiesToFetch = [\.id]
            found.formUnion(try context.fetch(d).map(\.id))
        }
        return found
    }

    /// The agent that added this workout (plan 32), or nil: the owner's own, deleted, or not on this iPhone.
    public func addedBy(_ id: UUID) throws -> String? {
        try record(id).flatMap { $0.deletedAt == nil ? $0.addedBy : nil }
    }

    /// Progression data points for one exercise, newest first (sessions without a done working set give none).
    ///
    /// Reads only the newest workouts with this exercise, a page at a time, until `limit` points exist: Today asks
    /// for 5 per plan item on every reload, and decoding every workout with a staple lift took ~14 ms each time.
    public func history(exerciseId: String, limit: Int) throws -> [SessionResult] {
        try finishedEntries(exerciseId: exerciseId, limit: limit) { SessionHistory.result(for: $1, date: $0) }
    }

    /// Whole entries (every set) for one exercise from finished workouts, newest first, with the
    /// workout's start date. Used for set-level trends such as e1RM and best set.
    public func sessions(exerciseId: String, limit: Int) throws -> [(date: Date, entry: WorkoutEntry)] {
        try finishedEntries(exerciseId: exerciseId, limit: limit) { (date: $0, entry: $1) }
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
        // What Health measured during it goes too (plan 40).
        try MeasurementRecord.remove(for: id, in: context)
        try context.save()
    }

    // MARK: - Private

    /// This exercise's entries from finished, non-deleted workouts, newest workout first (position order within a
    /// workout). The filter and sort run in SQL on the workout rows and entries come from their `entriesData` cache,
    /// so no entry/set rows are materialized (see `WorkoutRecord.entriesData`).
    private func finishedEntries(exerciseId: String) throws -> [(date: Date, entry: WorkoutEntry)] {
        try context.fetch(finishedDescriptor(exerciseId: exerciseId)).compactMap { workout in
            Self.entry(of: workout, exerciseId: exerciseId).map { (date: workout.startedAt, entry: $0) }
        }
    }

    /// The first `limit` values `keep` makes of this exercise's entries, newest workout first, reading the workouts
    /// `limit` at a time. Each page continues from the oldest start read so far and leaves out the workouts already
    /// read, so workouts that started at the same moment are each read once even across pages.
    private func finishedEntries<Value>(exerciseId: String, limit: Int,
                                        keep: (_ date: Date, _ entry: WorkoutEntry) -> Value?) throws -> [Value] {
        guard limit > 0 else { return [] }
        var values: [Value] = []
        var read: [UUID] = []
        var oldest = Date.distantFuture
        while values.count < limit {
            var descriptor = finishedDescriptor(exerciseId: exerciseId, startedAtOrBefore: oldest, excluding: read)
            descriptor.fetchLimit = limit
            let page = try context.fetch(descriptor)
            for workout in page {
                read.append(workout.id)
                guard values.count < limit, let entry = Self.entry(of: workout, exerciseId: exerciseId),
                      let value = keep(workout.startedAt, entry) else { continue }
                values.append(value)
            }
            guard page.count == limit, let last = page.last else { break }
            oldest = last.startedAt
        }
        return values
    }

    /// Finished, non-deleted workouts with this exercise, newest first; `startedAtOrBefore` and `excluding` page
    /// through them.
    private func finishedDescriptor(exerciseId: String, startedAtOrBefore latest: Date = .distantFuture,
                                    excluding read: [UUID] = []) -> FetchDescriptor<WorkoutRecord> {
        FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { workout in
                workout.deletedAt == nil && !workout.isActive && workout.startedAt <= latest
                    && !read.contains(workout.id) && workout.entries.contains { $0.exerciseId == exerciseId }
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
    }

    /// The workout's entry for this exercise. One session per workout: entries of the same exercise within a workout
    /// (e.g. the exercise in two supersets) are merged, so progression never sees them as separate, shorter sessions.
    private static func entry(of workout: WorkoutRecord, exerciseId: String) -> WorkoutEntry? {
        let entries = workout.entryValues.filter { $0.exerciseId == exerciseId }
        guard let first = entries.first else { return nil }
        return entries.count == 1 ? first
            : WorkoutEntry(id: first.id, exerciseId: exerciseId, sets: entries.flatMap(\.sets), note: first.note,
                           supersetGroup: first.supersetGroup, gymListingId: first.gymListingId)
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
        r.gymId = w.gymId
        r.isActive = isActive
        r.deletedAt = nil
        try r.setEntries(w.entries, in: context)
        r.updatedAt = now()
        r.dirty = !isActive
        return r
    }
}
