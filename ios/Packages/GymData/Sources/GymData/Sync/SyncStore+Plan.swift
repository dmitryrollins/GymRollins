import Foundation
import GymCore
import SwiftData

// Routines and the week schedule.
extension SyncStore {
    // MARK: Routines

    public func dirtyRoutines() throws -> [SyncRow<RoutineSnapshot>] {
        try context.fetch(FetchDescriptor<RoutineRecord>(predicate: #Predicate { $0.dirty },
                                                         sortBy: [SortDescriptor(\.position)]))
            .map { SyncRow(value: RoutineSnapshot(routine: $0.value, position: $0.position), clientUpdatedAt: $0.updatedAt,
                           deletedAt: $0.deletedAt, serverUpdatedAt: $0.serverUpdatedAt) }
    }

    public func applyRemote(routines rows: [SyncRow<RoutineSnapshot>]) throws {
        for row in rows {
            let routine = row.value.routine
            let existing = try routineRecord(routine.id)
            if let existing, !remoteWins(over: existing, remoteEdit: row.clientUpdatedAt) { continue }
            if existing == nil && row.deletedAt != nil { continue }
            let r = existing ?? {
                let new = RoutineRecord(id: routine.id, name: routine.name, emoji: routine.emoji,
                                        policyRaw: routine.policy.rawValue, position: row.value.position,
                                        paused: routine.paused, now: row.clientUpdatedAt)
                context.insert(new)
                return new
            }()
            r.name = routine.name
            r.emoji = routine.emoji
            r.policyRaw = routine.policy.rawValue
            r.position = row.value.position
            r.paused = routine.paused
            r.deletedAt = row.deletedAt
            r.exercises.forEach(context.delete)
            r.exercises = routine.exercises.enumerated().map { RoutineExerciseRecord($1, position: $0) }
            markClean(r, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: row.serverUpdatedAt)
        }
        try context.save()
    }

    // MARK: Week schedule

    public func dirtyWeekdays() throws -> [SyncRow<WeekdayAssignment>] {
        try context.fetch(FetchDescriptor<WeekdayRecord>(predicate: #Predicate { $0.dirty },
                                                         sortBy: [SortDescriptor(\.weekday)]))
            .map { SyncRow(value: WeekdayAssignment(weekday: $0.weekday, routineId: $0.routineId),
                           clientUpdatedAt: $0.updatedAt, serverUpdatedAt: $0.serverUpdatedAt) }
    }

    public func applyRemote(weekdays rows: [SyncRow<WeekdayAssignment>]) throws {
        for row in rows where (1...7).contains(row.value.weekday) {
            let existing = try weekdayRecord(row.value.weekday)
            if let existing, !remoteWins(over: existing, remoteEdit: row.clientUpdatedAt) { continue }
            let r = existing ?? {
                let new = WeekdayRecord(weekday: row.value.weekday, routineId: nil, now: row.clientUpdatedAt)
                context.insert(new)
                return new
            }()
            r.routineId = row.value.routineId
            markClean(r, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: row.serverUpdatedAt)
        }
        try context.save()
    }
}
