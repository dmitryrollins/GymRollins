import Foundation
import GymCore
import SwiftData

// Outside workouts and days of activity (plan 39). Only the Apple Health import writes them, so a pulled row replaces
// the local one by plain last-write-wins. A pulled tombstone with no local row is kept: it tells the import that Health
// deleted that workout, which would otherwise come back with the next import and revive the row through sync.
extension SyncStore {
    public func dirtyHealthActivities() throws -> [SyncRow<HealthActivity>] {
        try context.fetch(FetchDescriptor<HealthActivityRecord>(predicate: #Predicate { $0.dirty }))
            .map { SyncRow(value: $0.value, clientUpdatedAt: $0.updatedAt, deletedAt: $0.deletedAt,
                           serverUpdatedAt: $0.serverUpdatedAt) }
    }

    public func applyRemote(healthActivities rows: [SyncRow<HealthActivity>]) throws {
        for row in rows {
            let existing = try healthActivityRecord(row.value.id)
            if let existing, !remoteWins(over: existing, remoteEdit: row.clientUpdatedAt) { continue }
            let r = existing ?? {
                let new = HealthActivityRecord(row.value, now: row.clientUpdatedAt)
                context.insert(new)
                return new
            }()
            r.apply(row.value)
            r.deletedAt = row.deletedAt
            markClean(r, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: row.serverUpdatedAt)
        }
        try context.save()
    }

    public func dirtyActivityDays() throws -> [SyncRow<ActivityDay>] {
        try context.fetch(FetchDescriptor<ActivityDayRecord>(predicate: #Predicate { $0.dirty },
                                                             sortBy: [SortDescriptor(\.day)]))
            .map { SyncRow(value: $0.value, clientUpdatedAt: $0.updatedAt, serverUpdatedAt: $0.serverUpdatedAt) }
    }

    /// Applies pulled days (last write wins against dirty local rows); one this app can't store is skipped.
    public func applyRemote(activityDays rows: [SyncRow<ActivityDay>]) throws {
        for row in rows where DomainLimits.activityDayViolation(row.value) == nil {
            let existing = try activityDayRecord(row.value.day)
            if let existing, !remoteWins(over: existing, remoteEdit: row.clientUpdatedAt) { continue }
            let r = existing ?? {
                let new = ActivityDayRecord(row.value, now: row.clientUpdatedAt)
                context.insert(new)
                return new
            }()
            r.apply(row.value)
            markClean(r, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: row.serverUpdatedAt)
        }
        try context.save()
    }

    func healthActivityRecord(_ id: UUID) throws -> HealthActivityRecord? {
        try context.fetch(FetchDescriptor<HealthActivityRecord>(predicate: #Predicate { $0.id == id })).first
    }

    func activityDayRecord(_ day: String) throws -> ActivityDayRecord? {
        try context.fetch(FetchDescriptor<ActivityDayRecord>(predicate: #Predicate { $0.day == day })).first
    }
}
