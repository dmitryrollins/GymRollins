import Foundation
import GymCore
import SwiftData

@MainActor
public final class RoutineRepository {
    private let context: ModelContext
    private let now: () -> Date

    /// False for a transaction-scoped repository: writes are staged in the context and the caller saves (or
    /// rolls back) once for the whole transaction.
    private let autosave: Bool

    public convenience init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.init(context: context, now: now, autosave: true)
    }

    init(context: ModelContext, now: @escaping () -> Date, autosave: Bool) {
        self.context = context
        self.now = now
        self.autosave = autosave
    }

    private func persist() throws {
        if autosave { try context.save() }
    }

    public func all() throws -> [Routine] {
        let descriptor = FetchDescriptor<RoutineRecord>(predicate: #Predicate { $0.deletedAt == nil },
                                                        sortBy: [SortDescriptor(\.position)])
        return try context.fetch(descriptor).map(\.value)
    }

    public func routine(_ id: UUID) throws -> Routine? {
        guard let r = try record(id), r.deletedAt == nil else { return nil }
        return r.value
    }

    func record(_ id: UUID) throws -> RoutineRecord? {
        try context.fetch(FetchDescriptor<RoutineRecord>(predicate: #Predicate { $0.id == id })).first
    }

    /// Inserts or replaces a routine. Throws `GymDataError.invalidInput` for a name/exercise count the server would
    /// reject (`DomainLimits`).
    public func upsert(_ routine: Routine) throws {
        if let violation = DomainLimits.routineViolation(routine) { throw GymDataError.invalidInput(violation) }
        let existing = try record(routine.id)
        let r = existing ?? {
            let count = (try? context.fetchCount(FetchDescriptor<RoutineRecord>())) ?? 0
            let new = RoutineRecord(id: routine.id, name: routine.name, emoji: routine.emoji,
                                    policyRaw: routine.policy.rawValue, position: count, paused: routine.paused, now: now())
            context.insert(new)
            return new
        }()
        r.name = routine.name
        r.emoji = routine.emoji
        r.policyRaw = routine.policy.rawValue
        r.paused = routine.paused
        r.deletedAt = nil
        r.exercises.forEach(context.delete)
        r.exercises = routine.exercises.enumerated().map { RoutineExerciseRecord($1, position: $0) }
        r.updatedAt = now()
        r.dirty = true
        try persist()
    }

    public func delete(_ id: UUID) throws {
        guard let r = try record(id) else { return }
        r.deletedAt = now()
        r.updatedAt = now()
        r.dirty = true
        let weekdays = try context.fetch(FetchDescriptor<WeekdayRecord>()).filter { $0.routineId == id }
        weekdays.forEach { $0.routineId = nil; $0.updatedAt = now(); $0.dirty = true }
        try persist()
    }

    public func schedule() throws -> WeekSchedule {
        let days = try context.fetch(FetchDescriptor<WeekdayRecord>())
            .compactMap { r in r.routineId.map { (r.weekday, $0) } }
        return WeekSchedule(days: Dictionary(uniqueKeysWithValues: days))
    }

    public func setSchedule(weekday: Int, routineId: UUID?) throws {
        guard (1...7).contains(weekday) else { throw GymDataError.invalidInput("ISO weekday 1…7") }
        let existing = try context.fetch(FetchDescriptor<WeekdayRecord>(predicate: #Predicate { $0.weekday == weekday })).first
        let r = existing ?? { let new = WeekdayRecord(weekday: weekday, routineId: nil, now: now()); context.insert(new); return new }()
        r.routineId = routineId
        r.updatedAt = now()
        r.dirty = true
        try persist()
    }
}
