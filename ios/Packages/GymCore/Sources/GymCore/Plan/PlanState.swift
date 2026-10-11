import Foundation

/// The whole editable plan: routines (in list order) and the week schedule (ISO weekday 1 = Monday … 7 = Sunday →
/// routine id; a missing day is a rest day). The unit `PlanChangeApplier` works on, and what a proposal's undo
/// snapshot stores.
public struct PlanState: Codable, Sendable, Equatable {
    public let routines: [Routine]
    public let schedule: [Int: UUID]

    public init(routines: [Routine], schedule: [Int: UUID]) {
        self.routines = routines
        self.schedule = schedule
    }

    /// The validator's view of this plan. Routine ids are lowercased UUID strings, as the server (and so Claude)
    /// spells them.
    public var snapshot: PlanSnapshot {
        PlanSnapshot(routines: routines.map { routine in
            var reps: [String: Int] = [:]
            var repsMin: [String: Int] = [:]
            for item in routine.exercises {
                reps[item.exerciseId] = item.reps
                if let min = item.repsMin { repsMin[item.exerciseId] = min }
            }
            return PlanSnapshot.RoutineRef(id: routine.id.uuidString.lowercased(), name: routine.name,
                                           exerciseIds: routine.exercises.map(\.exerciseId), reps: reps,
                                           repsMin: repsMin, paused: routine.paused)
        })
    }
}

public enum PlanApplyError: Error, Equatable, Sendable {
    /// The change (by id) references a routine or exercise that isn't in the plan, or lacks a required value.
    case invalid(String)
}
