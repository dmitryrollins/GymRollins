/// Mutable per-change validation scratchpad shared by every change family: field helpers
/// (fail/require/range/name), routine/exercise lookups, and the routine state after applying
/// this one change (only actually applied when the change turned out valid).
final class PlanChangeChecker {
    private let exerciseExists: @Sendable (String) -> Bool
    private let change: PlanChange
    private(set) var violations: [PlanViolation] = []
    private(set) var routines: [String: PlanChangeValidator.RoutineState]
    private(set) var routineExercises: [String]?

    init(exerciseExists: @escaping @Sendable (String) -> Bool, change: PlanChange,
         routines: [String: PlanChangeValidator.RoutineState]) {
        self.exerciseExists = exerciseExists
        self.change = change
        self.routines = routines
    }

    /// Resolves `change.routineId` (when this change type needs one) before any family runs.
    func prepare() {
        routineExercises = resolveRoutine()
    }

    // MARK: - Shared field helpers

    func fail(_ field: String, _ message: String) {
        violations.append(PlanViolation(changeId: change.id, field: field, message: message))
    }

    func require<T>(_ value: T?, _ field: String) -> T? {
        if value == nil { fail(field, "Required for \(change.type.rawValue)") }
        return value
    }

    func range<T: Comparable>(_ value: T?, _ field: String, _ bounds: ClosedRange<T>, required: Bool = true) {
        guard let value = required ? require(value, field) : value else { return }
        if !bounds.contains(value) { fail(field, "Must be \(bounds.lowerBound)–\(bounds.upperBound)") }
    }

    func name(_ value: String?) {
        guard let value = require(value, "name") else { return }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.count > PlanChangeValidator.maxName {
            fail("name", "Name must be 1–\(PlanChangeValidator.maxName) characters")
        }
    }

    private func resolveRoutine() -> [String]? {
        if change.type == .addRoutine || change.type == .week { return nil }
        guard let id = require(change.routineId, "routineId") else { return nil }
        guard let state = routines[id] else { fail("routineId", "Unknown routine '\(id)'"); return nil }
        return state.exerciseIds
    }

    func inRoutine(_ id: String?, _ field: String) -> String? {
        guard let id = require(id, field), let list = routineExercises else { return nil }
        if !list.contains(id) { fail(field, "'\(id)' is not in this routine"); return nil }
        return id
    }

    func inLibrary(_ id: String?, _ field: String) -> String? {
        guard let id = require(id, field) else { return nil }
        if !exerciseExists(id) { fail(field, "Unknown exercise '\(id)'"); return nil }
        return id
    }

    // MARK: - Routine/effective-reps mutation (only takes effect when this change is valid so far)

    func updateRoutine(_ id: String, exerciseIds: [String]) {
        guard violations.isEmpty else { return }
        routines[id]?.exerciseIds = exerciseIds
    }

    func addRoutine(_ id: String) {
        guard violations.isEmpty else { return }
        routines[id] = PlanChangeValidator.RoutineState(exerciseIds: [], reps: [:], repsMin: [:])
    }

    func setPaused(_ id: String, _ paused: Bool) {
        guard violations.isEmpty else { return }
        routines[id]?.paused = paused
    }

    func removeRoutine(_ id: String) {
        guard violations.isEmpty else { return }
        routines.removeValue(forKey: id)
    }

    func effectiveReps(_ routineId: String?, _ exerciseId: String?) -> Int? {
        guard let routineId, let exerciseId else { return nil }
        return routines[routineId]?.reps[exerciseId]
    }

    func effectiveRepsMin(_ routineId: String?, _ exerciseId: String?) -> Int? {
        guard let routineId, let exerciseId else { return nil }
        return routines[routineId]?.repsMin[exerciseId]
    }

    func setEffectiveReps(_ routineId: String, _ exerciseId: String, reps: Int?, repsMin: Int?) {
        guard violations.isEmpty else { return }
        if let reps { routines[routineId]?.reps[exerciseId] = reps }
        if let repsMin { routines[routineId]?.repsMin[exerciseId] = repsMin }
    }

    func moveEffectiveReps(_ routineId: String, from: String, to: String) {
        guard violations.isEmpty else { return }
        if let reps = routines[routineId]?.reps.removeValue(forKey: from) { routines[routineId]?.reps[to] = reps }
        if let min = routines[routineId]?.repsMin.removeValue(forKey: from) { routines[routineId]?.repsMin[to] = min }
    }

    func removeEffectiveReps(_ routineId: String, _ exerciseId: String) {
        guard violations.isEmpty else { return }
        routines[routineId]?.reps.removeValue(forKey: exerciseId)
        routines[routineId]?.repsMin.removeValue(forKey: exerciseId)
    }
}

// MARK: - Exercise edits (add/remove/swap an exercise within a routine)

extension PlanChangeChecker {
    func checkExerciseEdit() {
        switch change.type {
        case .addExercise:
            checkAddExercise()
        case .removeExercise:
            if let id = inRoutine(change.exerciseId, "exerciseId"), let rid = change.routineId,
               let list = routineExercises {
                updateRoutine(rid, exerciseIds: list.filter { $0 != id })
                removeEffectiveReps(rid, id)
            }
        case .swapExercise:
            checkSwapExercise()
        default:
            break
        }
    }

    private func checkAddExercise() {
        let id = inLibrary(change.exerciseId, "exerciseId")
        range(change.sets, "sets", PlanChangeLimits.sets)
        range(change.reps, "reps", PlanChangeLimits.reps)
        optionalTargets(topReps: change.reps)
        range(change.position, "position", PlanChangeLimits.position, required: false)
        guard let id, let list = routineExercises, let rid = change.routineId else { return }
        if list.contains(id) {
            fail("exerciseId", "Already in routine")
        } else if list.count >= PlanChangeValidator.maxExercisesPerRoutine {
            fail("exerciseId", "Routine is full")
        } else if violations.isEmpty {
            updateRoutine(rid, exerciseIds: list + [id])
            setEffectiveReps(rid, id, reps: change.reps, repsMin: change.repsMin)
        }
    }

    private func checkSwapExercise() {
        let from = inRoutine(change.exerciseId, "exerciseId")
        let to = inLibrary(change.toExerciseId, "toExerciseId")
        if let to, let list = routineExercises, list.contains(to) { fail("toExerciseId", "Already in routine") }
        range(change.sets, "sets", PlanChangeLimits.sets, required: false)
        range(change.reps, "reps", PlanChangeLimits.reps, required: false)
        optionalTargets(topReps: change.reps ?? effectiveReps(change.routineId, from))
        guard violations.isEmpty, let from, let to, let rid = change.routineId, let list = routineExercises else {
            return
        }
        updateRoutine(rid, exerciseIds: list.map { $0 == from ? to : $0 })
        moveEffectiveReps(rid, from: from, to: to)
        setEffectiveReps(rid, to, reps: change.reps, repsMin: change.repsMin)
    }

    /// Optional prescription values an add/swap may carry (all consumed by the applier): each must be in range
    /// when present, and repsMin must not exceed the top of the rep range (when known).
    private func optionalTargets(topReps: Int?) {
        range(change.sec, "sec", PlanChangeLimits.sec, required: false)
        range(change.minutes, "minutes", PlanChangeLimits.minutes, required: false)
        range(change.weightKg, "weightKg", PlanChangeLimits.weightKg, required: false)
        if let min = change.repsMin, min < 1 || min > (topReps ?? PlanChangeLimits.reps.upperBound) {
            fail("repsMin", "Must be 1–reps")
        }
    }
}

// MARK: - Value edits (per-exercise numeric/policy fields on an existing routine exercise)

extension PlanChangeChecker {
    func checkValueEdit() {
        switch change.type {
        case .sets:
            _ = inRoutine(change.exerciseId, "exerciseId"); range(change.sets, "sets", PlanChangeLimits.sets)
        case .reps:
            _ = inRoutine(change.exerciseId, "exerciseId"); checkReps()
        case .repsMin:
            _ = inRoutine(change.exerciseId, "exerciseId"); checkRepsMin()
        case .sec:
            _ = inRoutine(change.exerciseId, "exerciseId"); range(change.sec, "sec", PlanChangeLimits.sec)
        case .weight:
            _ = inRoutine(change.exerciseId, "exerciseId"); range(change.weightKg, "weightKg", PlanChangeLimits.weightKg)
        case .cardio:
            _ = inRoutine(change.exerciseId, "exerciseId"); range(change.minutes, "minutes", PlanChangeLimits.minutes)
            range(change.speed, "speed", PlanChangeLimits.speed, required: false)
        case .reorder:
            _ = inRoutine(change.exerciseId, "exerciseId")
            range(change.position, "position", PlanChangeLimits.position)
        case .superset:
            checkSuperset()
        case .routineProg:
            _ = require(change.policy, "policy")
        case .exerciseProg:
            _ = inRoutine(change.exerciseId, "exerciseId"); _ = require(change.policy, "policy")
        case .inc:
            _ = inRoutine(change.exerciseId, "exerciseId"); range(change.incKg, "incKg", PlanChangeLimits.incKg)
        default:
            break
        }
    }

    // A `.reps` (top-of-range) change: repsMin — given explicitly on this change, or otherwise
    // the effective repsMin carried over from an earlier change or the snapshot — must not
    // exceed the new reps value.
    private func checkReps() {
        range(change.reps, "reps", PlanChangeLimits.reps)
        guard let newReps = change.reps, let rid = change.routineId, let exerciseId = change.exerciseId else {
            return
        }
        if let explicitMin = change.repsMin {
            if explicitMin < 1 || explicitMin > newReps { fail("repsMin", "Must be 1–reps") }
        } else if let effectiveMin = effectiveRepsMin(rid, exerciseId), effectiveMin > newReps {
            fail("repsMin", "Must be 1–reps")
        }
        setEffectiveReps(rid, exerciseId, reps: newReps, repsMin: change.repsMin)
    }

    // A `.repsMin` change must not exceed the effective reps (top of range), when known.
    private func checkRepsMin() {
        range(change.repsMin, "repsMin", PlanChangeLimits.reps)
        guard let newMin = change.repsMin, let rid = change.routineId, let exerciseId = change.exerciseId else {
            return
        }
        if let effectiveMax = effectiveReps(rid, exerciseId), newMin > effectiveMax {
            fail("repsMin", "Must be ≤ reps")
        }
        setEffectiveReps(rid, exerciseId, reps: nil, repsMin: newMin)
    }

    private func checkSuperset() {
        let a = inRoutine(change.exerciseId, "exerciseId")
        let b = inRoutine(change.withExerciseId, "withExerciseId")
        if let a, let b, a == b { fail("withExerciseId", "Can't superset an exercise with itself") }
    }
}

// MARK: - Routine edits (whole-routine management)

extension PlanChangeChecker {
    func checkRoutineEdit() {
        switch change.type {
        case .addRoutine:
            name(change.name)
            if let id = require(change.routineId, "routineId") {
                if routines[id] != nil {
                    fail("routineId", "Routine id already exists")
                } else if routines.count >= PlanChangeValidator.maxRoutines {
                    fail("routineId", "At most \(PlanChangeValidator.maxRoutines) routines")
                } else {
                    addRoutine(id)
                }
            }
        case .removeRoutine:
            if routineExercises != nil, let rid = change.routineId { removeRoutine(rid) }
        case .renameRoutine:
            name(change.name)
        case .pauseRoutine:
            if let paused = require(change.paused, "paused"), routineExercises != nil, let rid = change.routineId {
                setPaused(rid, paused)
            }
        default:
            break
        }
    }
}

// MARK: - Week (schedule) edits

extension PlanChangeChecker {
    func checkWeek() {
        range(change.weekday, "weekday", 1...7)
        if let rid = change.routineId, routines[rid] == nil { fail("routineId", "Unknown routine '\(rid)'") }
    }
}

// MARK: - Today (a one-off routine for one date; the schedule is untouched)

extension PlanChangeChecker {
    /// The routine must exist and not be paused (after earlier changes); `date` must be a real yyyy-MM-dd from the
    /// owner's `today` to `PlanChangeLimits.todayDaysAhead` days ahead, widened by `slack` days on both sides.
    func checkToday(today: String?, slack: Int) {
        if routineExercises != nil, let rid = change.routineId, routines[rid]?.paused == true {
            fail("routineId", "Routine is paused")
        }
        guard let date = require(change.date, "date") else { return }
        guard let day = PlanDay.number(date) else {
            fail("date", "Must be a date like 2026-10-03")
            return
        }
        guard let reference = today.flatMap(PlanDay.number) else { return }
        let ahead = day - reference
        let window = PlanChangeLimits.todayDaysAhead
        if ahead < window.lowerBound - slack {
            fail("date", "Date passed")
        } else if ahead > window.upperBound + slack {
            fail("date", "At most \(window.upperBound) days ahead")
        }
    }
}
