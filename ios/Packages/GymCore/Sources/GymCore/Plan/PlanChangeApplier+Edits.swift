import Foundation

/// Mutable mirrors of `Routine`/`RoutineExercise`, local to one `PlanChangeApplier.apply` call.
struct RoutineDraft {
    let id: UUID
    var name: String
    let emoji: String?
    var policy: ProgressionPolicy
    var paused: Bool
    var exercises: [ExerciseDraft]

    init(_ r: Routine) {
        id = r.id
        name = r.name
        emoji = r.emoji
        policy = r.policy
        paused = r.paused
        exercises = r.exercises.map(ExerciseDraft.init)
    }

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
        emoji = nil
        policy = .double
        paused = false
        exercises = []
    }

    var value: Routine {
        Routine(id: id, name: name, emoji: emoji, policy: policy, paused: paused, exercises: exercises.map(\.value))
    }
}

struct ExerciseDraft {
    let id: UUID
    var exerciseId: String
    var sets: Int
    var reps: Int
    var repsMin: Int?
    var sec: Int?
    var weightKg: Double?
    var mode: ExerciseMode
    var policy: ProgressionPolicy?
    var incKg: Double?
    var supersetGroup: String?
    var weightSetAt: Date?

    init(_ e: RoutineExercise) {
        id = e.id
        exerciseId = e.exerciseId
        sets = e.sets
        reps = e.reps
        repsMin = e.repsMin
        sec = e.sec
        weightKg = e.weightKg
        mode = e.mode
        policy = e.policy
        incKg = e.incKg
        supersetGroup = e.supersetGroup
        weightSetAt = e.weightSetAt
    }

    var value: RoutineExercise {
        RoutineExercise(id: id, exerciseId: exerciseId, sets: sets, reps: reps, repsMin: repsMin, sec: sec,
                        weightKg: weightKg, mode: mode, policy: policy, incKg: incKg, supersetGroup: supersetGroup,
                        weightSetAt: weightSetAt)
    }
}

// MARK: - Checked values (defense in depth: throw, never trap, on anything the validator should have refused)

extension PlanDraft {
    /// `value` when it is nil or inside `bounds` (NaN never is); otherwise the change is invalid.
    static func checked<T: Comparable>(_ value: T?, _ bounds: ClosedRange<T>, _ c: PlanChange) throws -> T? {
        guard let value else { return nil }
        guard bounds.contains(value) else { throw PlanApplyError.invalid(c.id) }
        return value
    }

    static func requiredIn<T: Comparable>(_ value: T?, _ bounds: ClosedRange<T>, _ c: PlanChange) throws -> T {
        try required(checked(value, bounds, c), c)
    }

    /// Target seconds from `sec`, else `minutes` (converted only once it is known to be in range).
    static func seconds(_ c: PlanChange) throws -> Int? {
        if let sec = try checked(c.sec, PlanChangeLimits.sec, c) { return sec }
        return try checked(c.minutes, PlanChangeLimits.minutes, c).map { Int(($0 * 60).rounded()) }
    }

    /// repsMin, when given, must lie in 1...top.
    static func repsMin(_ c: PlanChange, top: Int) throws -> Int? {
        try checked(c.repsMin, 1...max(top, 1), c)
    }
}

// MARK: - Change families

extension PlanDraft {
    mutating func addExercise(_ c: PlanChange, now: Date, mode: (String) -> ExerciseMode) throws {
        let r = try routineIndex(c)
        let exerciseId = try Self.required(c.exerciseId, c)
        guard !routines[r].exercises.contains(where: { $0.exerciseId == exerciseId }) else {
            throw PlanApplyError.invalid(c.id)
        }
        let kind = mode(exerciseId)
        let reps = try Self.requiredIn(c.reps, PlanChangeLimits.reps, c)
        let weight = try Self.checked(c.weightKg, PlanChangeLimits.weightKg, c)
        let sec = try Self.seconds(c) ?? RoutineExercise.defaults(exerciseId: exerciseId, mode: kind, barbell: false).sec
        let item = RoutineExercise(exerciseId: exerciseId, sets: try Self.requiredIn(c.sets, PlanChangeLimits.sets, c),
                                   reps: reps, repsMin: try Self.repsMin(c, top: reps), sec: sec,
                                   weightKg: weight, mode: kind, weightSetAt: weight == nil ? nil : now)
        let position = min(max(c.position ?? routines[r].exercises.count, 0), routines[r].exercises.count)
        routines[r].exercises.insert(ExerciseDraft(item), at: position)
    }

    /// Swaps the exercise in place. Across modes the prescription is reset to the new mode's defaults (a rep
    /// target means nothing for a timed exercise and vice versa); targets the change supplies win either way.
    mutating func swapExercise(_ c: PlanChange, now: Date, mode: (String) -> ExerciseMode) throws {
        let r = try routineIndex(c)
        let e = try exerciseIndex(c, in: r)
        let to = try Self.required(c.toExerciseId, c)
        guard !routines[r].exercises.contains(where: { $0.exerciseId == to }) else { throw PlanApplyError.invalid(c.id) }
        var item = routines[r].exercises[e]
        let kind = mode(to)
        if kind != item.mode {
            let d = RoutineExercise.defaults(exerciseId: to, mode: kind, barbell: false)
            (item.sets, item.reps, item.repsMin, item.sec, item.incKg) = (d.sets, d.reps, d.repsMin, d.sec, nil)
        }
        item.exerciseId = to
        item.mode = kind
        item.sets = try Self.checked(c.sets, PlanChangeLimits.sets, c) ?? item.sets
        item.reps = try Self.checked(c.reps, PlanChangeLimits.reps, c) ?? item.reps
        item.repsMin = try Self.repsMin(c, top: item.reps) ?? item.repsMin.flatMap { $0 <= item.reps ? $0 : nil }
        item.sec = try Self.seconds(c) ?? item.sec
        // The old exercise's load means nothing for the new one: keep Claude's weight if given, else none.
        item.weightKg = try Self.checked(c.weightKg, PlanChangeLimits.weightKg, c)
        item.weightSetAt = item.weightKg == nil ? nil : now
        routines[r].exercises[e] = item
    }

    mutating func editExercise(_ c: PlanChange, now: Date) throws {
        let r = try routineIndex(c)
        let e = try exerciseIndex(c, in: r)
        var item = routines[r].exercises[e]
        switch c.type {
        case .sets: item.sets = try Self.requiredIn(c.sets, PlanChangeLimits.sets, c)
        case .reps:
            item.reps = try Self.requiredIn(c.reps, PlanChangeLimits.reps, c)
            if let min = try Self.repsMin(c, top: item.reps) { item.repsMin = min }
        case .repsMin: item.repsMin = try Self.requiredIn(c.repsMin, PlanChangeLimits.reps, c)
        case .sec: item.sec = try Self.requiredIn(c.sec, PlanChangeLimits.sec, c)
        case .weight:
            item.weightKg = try Self.requiredIn(c.weightKg, PlanChangeLimits.weightKg, c)
            item.weightSetAt = now // a planned weight: progression uses it as-is next session
        case .cardio: // speed has no plan field
            item.sec = Int((try Self.requiredIn(c.minutes, PlanChangeLimits.minutes, c) * 60).rounded())
        case .inc: item.incKg = try Self.requiredIn(c.incKg, PlanChangeLimits.incKg, c)
        case .exerciseProg: item.policy = try Self.required(c.policy, c)
        default: throw PlanApplyError.invalid(c.id)
        }
        routines[r].exercises[e] = item
    }

    mutating func reorder(_ c: PlanChange) throws {
        let r = try routineIndex(c)
        let e = try exerciseIndex(c, in: r)
        let position = try Self.required(c.position, c)
        let item = routines[r].exercises.remove(at: e)
        routines[r].exercises.insert(item, at: min(max(position, 0), routines[r].exercises.count))
    }

    /// Puts both exercises in one superset group: an existing group of either, else the first free letter.
    mutating func superset(_ c: PlanChange) throws {
        let r = try routineIndex(c)
        let a = try exerciseIndex(c, in: r)
        let b = try exerciseIndex(c, in: r, try Self.required(c.withExerciseId, c))
        guard a != b else { throw PlanApplyError.invalid(c.id) }
        let used = Set(routines[r].exercises.compactMap(\.supersetGroup))
        let group = routines[r].exercises[a].supersetGroup ?? routines[r].exercises[b].supersetGroup
            ?? "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init).first { !used.contains($0) } ?? c.id
        routines[r].exercises[a].supersetGroup = group
        routines[r].exercises[b].supersetGroup = group
    }

    mutating func addRoutine(_ c: PlanChange, newID: (String) -> UUID) throws {
        let ref = try Self.required(c.routineId, c)
        guard resolve(ref) == nil else { throw PlanApplyError.invalid(c.id) }
        let given = UUID(uuidString: ref)
        let id = given.flatMap { g in routines.contains { $0.id == g } ? nil : g } ?? newID(c.id)
        aliases[ref] = id
        routines.append(RoutineDraft(id: id, name: try Self.trimmedName(c)))
    }

    mutating func week(_ c: PlanChange) throws {
        let weekday = try Self.required(c.weekday, c)
        guard (1...7).contains(weekday) else { throw PlanApplyError.invalid(c.id) }
        guard let ref = c.routineId else {
            schedule.removeValue(forKey: weekday)
            return
        }
        guard let id = resolve(ref) else { throw PlanApplyError.invalid(c.id) }
        schedule[weekday] = id
    }

    /// Records the one-off routine; the routine must be there and not paused, and the date a real day.
    mutating func today(_ c: PlanChange) throws {
        let routine = routines[try routineIndex(c)]
        let day = try Self.required(c.date, c)
        guard !routine.paused, PlanDay.number(day) != nil else { throw PlanApplyError.invalid(c.id) }
        days.append(PlanDayRoutine(changeId: c.id, day: day, routineId: routine.id))
    }
}
