/// Validates Claude's proposals against the closed change list, value ranges and the current plan.
/// Mirrored in TypeScript (supabase/functions/_shared/validate.ts) using app/fixtures/plan-changes.json.
public struct PlanChangeValidator: Sendable {
    public static let maxChanges = 25
    public static let maxRoutines = 7
    public static let maxExercisesPerRoutine = DomainLimits.routineExercisesMax
    public static let maxSummary = 500
    public static let maxReason = 300
    public static let maxName = DomainLimits.routineNameMax

    /// Routine state threaded through a proposal: exercise membership plus effective rep ranges
    /// (exerciseId → value), so a later change can validate against reps/repsMin an earlier
    /// change in the same proposal set, without re-reading the original snapshot.
    struct RoutineState {
        var exerciseIds: [String]
        var reps: [String: Int]
        var repsMin: [String: Int]
        var paused = false
    }

    let plan: PlanSnapshot
    let exerciseExists: @Sendable (String) -> Bool
    /// The owner's yyyy-MM-dd that `today` changes are checked against (nil: only the date's format is checked).
    let today: String?
    /// Widens the `today` window by this many days on both sides (the server, which only knows UTC, uses 1).
    let daySlack: Int

    public init(plan: PlanSnapshot, exerciseExists: @escaping @Sendable (String) -> Bool, today: String? = nil,
                daySlack: Int = 0) {
        self.plan = plan
        self.exerciseExists = exerciseExists
        self.today = today
        self.daySlack = daySlack
    }

    public func validate(_ proposal: PlanProposal) -> [PlanViolation] {
        var out: [PlanViolation] = []
        let summary = proposal.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.isEmpty || summary.count > Self.maxSummary {
            out.append(PlanViolation(changeId: nil, field: "summary", message: "Summary must be 1–\(Self.maxSummary) characters"))
        }
        if proposal.changes.isEmpty || proposal.changes.count > Self.maxChanges {
            out.append(PlanViolation(changeId: nil, field: "changes", message: "1–\(Self.maxChanges) changes allowed"))
        }
        var seen = Set<String>()
        var routines = Dictionary(uniqueKeysWithValues: plan.routines.map {
            ($0.id, RoutineState(exerciseIds: $0.exerciseIds, reps: $0.reps ?? [:], repsMin: $0.repsMin ?? [:],
                                 paused: $0.paused ?? false))
        })
        var todayDates = Set<String>()
        for change in proposal.changes {
            if !seen.insert(change.id).inserted {
                out.append(PlanViolation(changeId: change.id, field: "id", message: "Duplicate change id"))
            }
            if change.type == .today, let date = change.date, !todayDates.insert(date).inserted {
                out.append(PlanViolation(changeId: change.id, field: "date",
                                         message: "Another change already picks this date"))
            }
            if let reason = change.reason, reason.count > Self.maxReason {
                out.append(PlanViolation(changeId: change.id, field: "reason", message: "Reason too long"))
            }
            let (violations, updated) = check(change, routines: routines)
            out.append(contentsOf: violations)
            routines = updated
        }
        return out
    }

    // Dispatches to the change family that knows how to validate (and, when valid, apply) this
    // change type. Kept deliberately tiny: the per-family logic lives in
    // PlanChangeValidator+Families.swift so this stays under SwiftLint's complexity limit.
    private func check(_ c: PlanChange, routines: [String: RoutineState]) -> ([PlanViolation], [String: RoutineState]) {
        let checker = PlanChangeChecker(exerciseExists: exerciseExists, change: c, routines: routines)
        checker.prepare()
        switch c.type {
        case .addExercise, .removeExercise, .swapExercise:
            checker.checkExerciseEdit()
        case .sets, .reps, .repsMin, .sec, .weight, .cardio, .reorder, .superset, .routineProg, .exerciseProg, .inc:
            checker.checkValueEdit()
        case .addRoutine, .removeRoutine, .renameRoutine, .pauseRoutine:
            checker.checkRoutineEdit()
        case .week:
            checker.checkWeek()
        case .today:
            checker.checkToday(today: today, slack: daySlack)
        }
        return (checker.violations, checker.violations.isEmpty ? checker.routines : routines)
    }
}
