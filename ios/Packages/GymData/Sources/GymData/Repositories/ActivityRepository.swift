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
        if let violation = DomainLimits.healthActivityViolation(activity) {
            throw GymDataError.invalidInput(violation)
        }
        guard try record(activity.id) == nil else { return false }
        context.insert(HealthActivityRecord(activity, now: editedAt))
        try context.save()
        return true
    }

    /// Health deleted it: the live row becomes a tombstone. False when there's no live row.
    @discardableResult
    public func delete(_ id: UUID) throws -> Bool {
        guard let r = try record(id), r.deletedAt == nil else { return false }
        let time = now()
        r.deletedAt = time
        // Never backwards: sync's last-write-wins compares edit times.
        r.updatedAt = max(time, r.updatedAt.addingTimeInterval(0.001))
        r.dirty = true
        try context.save()
        return true
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
        if let violation = DomainLimits.activityDayViolation(day) { throw GymDataError.invalidInput(violation) }
        let key = day.day
        let existing = try context.fetch(FetchDescriptor<ActivityDayRecord>(predicate: #Predicate { $0.day == key }))
        if let r = existing.first {
            guard r.value != day else { return false }
            r.apply(day)
            r.updatedAt = max(now(), r.updatedAt.addingTimeInterval(0.001))
            r.dirty = true
        } else {
            context.insert(ActivityDayRecord(day, now: now()))
        }
        try context.save()
        return true
    }

    private func record(_ id: UUID) throws -> HealthActivityRecord? {
        try context.fetch(FetchDescriptor<HealthActivityRecord>(predicate: #Predicate { $0.id == id })).first
    }
}
