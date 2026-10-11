import Foundation
import GymCore

// The whole plan as one value, for applying proposals and restoring their snapshots.
extension RoutineRepository {
    public func planState() throws -> PlanState {
        PlanState(routines: try all(), schedule: try schedule().days)
    }

    /// Makes the stored plan equal `plan`: changed or restored routines are upserted, routines missing from `plan`
    /// are deleted (tombstoned), and changed weekdays are reassigned. Only what differs is written (and goes dirty
    /// for sync). Every routine is checked against `DomainLimits` before anything is written.
    public func save(plan: PlanState) throws {
        for routine in plan.routines {
            if let violation = DomainLimits.routineViolation(routine) { throw GymDataError.invalidInput(violation) }
        }
        let current = try planState()
        let currentById = Dictionary(current.routines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for routine in plan.routines where currentById[routine.id] != routine {
            try upsert(routine)
        }
        let kept = Set(plan.routines.map(\.id))
        for old in current.routines where !kept.contains(old.id) {
            try delete(old.id)
        }
        let afterDeletes = try schedule().days
        for weekday in 1...7 where afterDeletes[weekday] != plan.schedule[weekday] {
            try setSchedule(weekday: weekday, routineId: plan.schedule[weekday])
        }
    }
}
