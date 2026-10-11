import Foundation
import GymCore
import GymData

/// Turns a proposal's changes into review rows: a type label, "before → after" text in the owner's unit, Claude's
/// reason, and why a change can't be applied (from the validator). Each row's "before" is the plan with the
/// proposal's earlier (valid) changes already applied, so e.g. a rename followed by a pause reads naturally.
enum ProposalModel {
    struct Row: Equatable, Identifiable {
        let id: String
        let label: String
        let text: String
        let reason: String?
        let invalidReason: String?
    }

    static let arrow = " \u{2192} "
    static let dash = " \u{2014} "
    private static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "Sat 3 Oct" for a yyyy-MM-dd, with "Today (…)" / "Tomorrow (…)" relative to `today`; the raw text otherwise.
    static func dayTitle(_ date: String, today: String) -> String {
        guard let number = PlanDay.number(date), let month = Int(date.split(separator: "-")[1]),
              let day = Int(date.split(separator: "-")[2]) else { return date }
        let short = "\(dayName(isoWeekday(dayNumber: number))) \(day) \(monthNames[month - 1])"
        switch PlanDay.number(today).map({ number - $0 }) {
        case 0: return "Today (\(short))"
        case 1: return "Tomorrow (\(short))"
        default: return short
        }
    }

    /// ISO weekday (1 = Monday … 7 = Sunday) of a `PlanDay.number` (1970-01-01 was a Thursday).
    static func isoWeekday(dayNumber: Int) -> Int { ((dayNumber + 3) % 7 + 7) % 7 + 1 }

    /// `calendar` is the owner's: it decides which date is "Today" for a `today` change.
    // swiftlint:disable:next function_parameter_count
    static func rows(for changes: [PlanChange], plan: PlanState, library: ExerciseLibrary, unit: WeightUnit,
                     now: Date, violations: [String: String], calendar: Calendar = .current) -> [Row] {
        let today = PlanDay.key(now, calendar: calendar)
        var state = plan
        var applied: [PlanChange] = []
        let mode: (String) -> ExerciseMode = { library.exercise($0)?.mode ?? .reps }
        return changes.map { change in
            let before = state
            if violations[change.id] == nil,
               let after = try? PlanChangeApplier.apply(applied + [change], to: plan, now: now, mode: mode) {
                applied.append(change)
                state = after
            }
            let context = Context(change: change, before: before, after: state, changes: changes, library: library,
                                  unit: unit, today: today)
            return Row(id: change.id, label: label(change), text: context.text, reason: change.reason,
                       invalidReason: violations[change.id])
        }
    }

    private static let labels: [PlanChangeType: String] = [
        .addExercise: "Add", .removeExercise: "Remove", .removeRoutine: "Remove", .swapExercise: "Swap",
        .sets: "Sets", .reps: "Reps", .repsMin: "Reps", .sec: "Time", .weight: "Weight", .cardio: "Cardio",
        .reorder: "Order", .superset: "Superset", .routineProg: "Progression", .exerciseProg: "Progression",
        .inc: "Increment", .addRoutine: "New routine", .renameRoutine: "Rename", .week: "Schedule",
        .today: "Switch",
    ]

    static func label(_ c: PlanChange) -> String {
        if c.type == .pauseRoutine { return c.paused == false ? "Resume" : "Pause" }
        return labels[c.type] ?? c.type.rawValue
    }

    static func dayName(_ weekday: Int) -> String {
        (1...7).contains(weekday) ? dayNames[weekday - 1] : "Day \(weekday)"
    }

    static func policyName(_ policy: ProgressionPolicy) -> String { policy.rawValue.capitalized }

    /// "3 × 8–10 @ 140 lb", "3 × 45 s", "20 min".
    static func prescription(_ item: RoutineExercise, unit: WeightUnit) -> String {
        if item.mode == .cardio { return "\((item.sec ?? 0) / 60) min" }
        let reps = item.repsMin.map { $0 < item.reps ? "\($0)\u{2013}\(item.reps)" : "\(item.reps)" } ?? "\(item.reps)"
        let body = item.sec.map { "\(item.sets) \u{00D7} \($0) s" } ?? "\(item.sets) \u{00D7} \(reps)"
        guard let kg = item.weightKg, kg > 0 else { return body }
        return body + " @ " + weight(kg, unit)
    }

    static func weight(_ kg: Double, _ unit: WeightUnit) -> String {
        WeightFormatter.format(kg: kg, unit: unit, includeSecondary: false)
    }
}
