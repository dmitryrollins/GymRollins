import Foundation

/// Applies validated plan changes to a `PlanState`, purely: the input is never modified and the same inputs give
/// the same output. Run `PlanChangeValidator` first; this re-checks references only as defense in depth and throws
/// `PlanApplyError.invalid(changeId)` for a routine/exercise that isn't there or a missing required value.
///
/// Routine references are UUID strings (any case). `add-routine` keeps its `routineId` when it is a free UUID,
/// otherwise it gets `newID(changeId)` (pass `StableUUID.generator(namespace: proposalId)` so every device derives
/// the same id); either way later changes in the same batch can refer to it by the given string.
/// `aliases` pre-seeds that table (e.g. the shared fixture's "push"/"pull" names).
///
/// A `today` change doesn't touch the plan: `applyDetailed` reports it as a `PlanDayRoutine` for the app to show
/// on Today that day (the same as Switch), with its routine reference resolved.
public enum PlanChangeApplier {
    public static func apply(_ changes: [PlanChange], to plan: PlanState, now: Date,
                             mode: (String) -> ExerciseMode = { _ in .reps },
                             aliases: [String: UUID] = [:],
                             newID: (String) -> UUID = { _ in UUID() }) throws -> PlanState {
        try applyDetailed(changes, to: plan, now: now, mode: mode, aliases: aliases, newID: newID).plan
    }

    /// `apply`, plus the one-off routines its `today` changes pick (in change order).
    public static func applyDetailed(_ changes: [PlanChange], to plan: PlanState, now: Date,
                                     mode: (String) -> ExerciseMode = { _ in .reps },
                                     aliases: [String: UUID] = [:],
                                     newID: (String) -> UUID = { _ in UUID() }) throws -> PlanApplyResult {
        var draft = PlanDraft(plan, aliases: aliases)
        for change in changes {
            try draft.apply(change, now: now, mode: mode, newID: newID)
        }
        return PlanApplyResult(plan: draft.state, days: draft.days)
    }
}

/// A `today` change once applied: show `routineId` on Today on `day` (yyyy-MM-dd) only.
public struct PlanDayRoutine: Codable, Sendable, Equatable {
    public let changeId: String
    public let day: String
    public let routineId: UUID

    public init(changeId: String, day: String, routineId: UUID) {
        self.changeId = changeId
        self.day = day
        self.routineId = routineId
    }
}

public struct PlanApplyResult: Sendable, Equatable {
    public let plan: PlanState
    public let days: [PlanDayRoutine]
}

/// Working copy threaded through one `apply` call.
struct PlanDraft {
    var routines: [RoutineDraft]
    var schedule: [Int: UUID]
    var aliases: [String: UUID]
    /// What the batch's `today` changes picked.
    var days: [PlanDayRoutine] = []

    init(_ plan: PlanState, aliases: [String: UUID]) {
        routines = plan.routines.map(RoutineDraft.init)
        schedule = plan.schedule
        self.aliases = aliases
    }

    var state: PlanState { PlanState(routines: routines.map(\.value), schedule: schedule) }

    // MARK: Lookups

    func resolve(_ ref: String?) -> UUID? {
        guard let ref else { return nil }
        if let mapped = aliases[ref] { return mapped }
        guard let id = UUID(uuidString: ref), routines.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func routineIndex(_ c: PlanChange) throws -> Int {
        guard let id = resolve(c.routineId), let index = routines.firstIndex(where: { $0.id == id }) else {
            throw PlanApplyError.invalid(c.id)
        }
        return index
    }

    func exerciseIndex(_ c: PlanChange, in routine: Int, _ exerciseId: String? = nil) throws -> Int {
        guard let exerciseId = exerciseId ?? c.exerciseId,
              let index = routines[routine].exercises.firstIndex(where: { $0.exerciseId == exerciseId }) else {
            throw PlanApplyError.invalid(c.id)
        }
        return index
    }

    static func required<T>(_ value: T?, _ c: PlanChange) throws -> T {
        guard let value else { throw PlanApplyError.invalid(c.id) }
        return value
    }

    // MARK: Dispatch

    mutating func apply(_ c: PlanChange, now: Date, mode: (String) -> ExerciseMode, newID: (String) -> UUID) throws {
        switch c.type {
        case .addExercise: try addExercise(c, now: now, mode: mode)
        case .removeExercise:
            let r = try routineIndex(c)
            routines[r].exercises.remove(at: try exerciseIndex(c, in: r))
        case .swapExercise: try swapExercise(c, now: now, mode: mode)
        case .sets, .reps, .repsMin, .sec, .weight, .cardio, .inc, .exerciseProg:
            try editExercise(c, now: now)
        case .reorder: try reorder(c)
        case .superset: try superset(c)
        case .routineProg, .removeRoutine, .renameRoutine, .pauseRoutine: try editRoutine(c)
        case .addRoutine: try addRoutine(c, newID: newID)
        case .week: try week(c)
        case .today: try today(c)
        }
    }

    mutating func editRoutine(_ c: PlanChange) throws {
        let r = try routineIndex(c)
        switch c.type {
        case .routineProg: routines[r].policy = try Self.required(c.policy, c)
        case .removeRoutine:
            let id = routines.remove(at: r).id
            schedule = schedule.filter { $0.value != id }
        case .renameRoutine: routines[r].name = try Self.trimmedName(c)
        case .pauseRoutine: routines[r].paused = try Self.required(c.paused, c)
        default: throw PlanApplyError.invalid(c.id)
        }
    }

    static func trimmedName(_ c: PlanChange) throws -> String {
        let name = try required(c.name, c).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PlanApplyError.invalid(c.id) }
        return name
    }
}
