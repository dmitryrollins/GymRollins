import Foundation
import GymCore
import SwiftData

/// Outside workouts and days of activity read from Apple Health (plan 39). Only the Health import writes them and the
/// app only reads them: Health is their source of truth, so nothing here edits one.
@MainActor
public final class ActivityRepository {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    // MARK: Outside workouts

    /// Live outside workouts that started at or after `since` (all when nil), newest first.
    public func activities(since: Date?) throws -> [HealthActivity] {
        let start = since ?? .distantPast
        let d = FetchDescriptor<HealthActivityRecord>(
            predicate: #Predicate { $0.deletedAt == nil && $0.startedAt >= start },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return try context.fetch(d).map(\.value)
    }

    /// How many live outside workouts there are (a cheap check that one was added or deleted).
    public func liveCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<HealthActivityRecord>(predicate: #Predicate { $0.deletedAt == nil }))
    }

    /// The live outside workout with this id.
    public func activity(_ id: UUID) throws -> HealthActivity? {
        try record(id).flatMap { $0.deletedAt == nil ? $0.value : nil }
    }

    /// True when a row with this id exists, a tombstone included.
    public func hasRecord(id: UUID) throws -> Bool {
        try record(id) != nil
    }

    /// Stores a new outside workout with `editedAt` as its edit time. False when the id is already here, live or
    /// deleted: a tombstone never comes back. Throws for one outside `DomainLimits`.
    @discardableResult
    public func add(_ activity: HealthActivity, editedAt: Date) throws -> Bool {
        try !add([activity], editedAt: { _ in editedAt }).isEmpty
    }

    /// Stores the new outside workouts of a batch with one fetch and one save (the Health import runs on the main
    /// actor, and its first read can bring two years at once), each with the edit time `editedAt` gives it. Returns
    /// the ids it stored, in order. One whose id is already here, live or deleted, is skipped (a tombstone never comes
    /// back), and so is a repeat of an id earlier in the batch. Throws for one outside `DomainLimits`, before storing
    /// any.
    @discardableResult
    public func add(_ batch: [HealthActivity], editedAt: (HealthActivity) -> Date) throws -> [UUID] {
        if let violation = batch.lazy.compactMap(DomainLimits.healthActivityViolation).first {
            throw GymDataError.invalidInput(violation)
        }
        var known = Set(try records(batch.map(\.id)).map(\.id))
        var added: [UUID] = []
        for activity in batch {
            guard known.insert(activity.id).inserted else { continue }
            context.insert(HealthActivityRecord(activity, now: editedAt(activity)))
            added.append(activity.id)
        }
        if !added.isEmpty { try context.save() }
        return added
    }

    /// Health deleted it: the live row becomes a tombstone. False when there's no live row.
    @discardableResult
    public func delete(_ id: UUID) throws -> Bool {
        try !delete([id]).deleted.isEmpty
    }

    /// Health deleted these: each live row becomes a tombstone, with one fetch and one save. Returns, in order, the ids
    /// whose live row it tombstoned and the ids with no row here at all (repeats kept), which is what one call per id
    /// would tell. An id that is already a tombstone is in neither.
    public func delete(_ ids: [UUID]) throws -> (deleted: [UUID], missing: [UUID]) {
        let byId = Dictionary(try records(ids).map { ($0.id, $0) }, uniquingKeysWith: { kept, _ in kept })
        let time = now()
        var deleted: [UUID] = [], missing: [UUID] = []
        for id in ids {
            guard let r = byId[id] else {
                missing.append(id)
                continue
            }
            guard r.deletedAt == nil else { continue }
            r.deletedAt = time
            // Never backwards: sync's last-write-wins compares edit times.
            r.updatedAt = max(time, r.updatedAt.addingTimeInterval(0.001))
            r.dirty = true
            deleted.append(id)
        }
        if !deleted.isEmpty { try context.save() }
        return (deleted, missing)
    }

    // MARK: Days

    /// Days from `first` through `last` (`YYYY-MM-DD`, both included), oldest first.
    public func days(from first: String, through last: String) throws -> [ActivityDay] {
        let d = FetchDescriptor<ActivityDayRecord>(predicate: #Predicate { $0.day >= first && $0.day <= last },
                                                   sortBy: [SortDescriptor(\.day)])
        return try context.fetch(d).map(\.value)
    }

    /// Writes the day when it's new or a value changed, and says whether it wrote. Throws for one outside
    /// `DomainLimits`.
    @discardableResult
    public func save(day: ActivityDay) throws -> Bool {
        try !save(days: [day]).isEmpty
    }

    /// Writes the days of a batch that are new or whose values changed, with one fetch (the batch's range of days)
    /// and one save, and returns the days it wrote, in order. A day repeated in the batch is compared with the one
    /// before it, as one call per day would. Throws for one outside `DomainLimits`, before writing any.
    @discardableResult
    public func save(days batch: [ActivityDay]) throws -> [String] {
        if let violation = batch.lazy.compactMap(DomainLimits.activityDayViolation).first {
            throw GymDataError.invalidInput(violation)
        }
        guard let first = batch.map(\.day).min(), let last = batch.map(\.day).max() else { return [] }
        let stored = try context.fetch(FetchDescriptor<ActivityDayRecord>(
            predicate: #Predicate { $0.day >= first && $0.day <= last }))
        var byDay = Dictionary(stored.map { ($0.day, $0) }, uniquingKeysWith: { kept, _ in kept })
        let time = now()
        var written: [String] = []
        for day in batch {
            if let r = byDay[day.day] {
                guard r.value != day else { continue }
                r.apply(day)
                r.updatedAt = max(time, r.updatedAt.addingTimeInterval(0.001))
                r.dirty = true
            } else {
                let r = ActivityDayRecord(day, now: time)
                context.insert(r)
                byDay[day.day] = r
            }
            written.append(day.day)
        }
        if !written.isEmpty { try context.save() }
        return written
    }

    private func record(_ id: UUID) throws -> HealthActivityRecord? {
        try context.fetch(FetchDescriptor<HealthActivityRecord>(predicate: #Predicate { $0.id == id })).first
    }

    /// The rows (live or tombstones) with these ids.
    private func records(_ ids: [UUID]) throws -> [HealthActivityRecord] {
        try IdBatches.of(ids).flatMap { batch in
            try context.fetch(FetchDescriptor<HealthActivityRecord>(predicate: #Predicate { batch.contains($0.id) }))
        }
    }
}
