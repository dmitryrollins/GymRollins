import Foundation
import GymCore
import GymData

extension ProposalModel {
    /// One change with the plan just before and just after it.
    struct Context {
        let change: PlanChange
        let before: PlanState
        let after: PlanState
        let changes: [PlanChange]
        let library: ExerciseLibrary
        let unit: WeightUnit
        /// The owner's yyyy-MM-dd (for "Today (Sat 3 Oct)").
        let today: String

        var text: String {
            switch change.type {
            case .addExercise, .removeExercise, .swapExercise, .reorder, .superset: exerciseEditText
            case .sets, .reps, .repsMin, .sec, .weight, .cardio: valueText
            case .routineProg, .exerciseProg, .inc: progressionText
            case .addRoutine, .removeRoutine, .renameRoutine, .pauseRoutine, .week: routineText
            case .today: todayText
            }
        }

        // MARK: Lookups

        func exerciseName(_ id: String?) -> String {
            guard let id else { return "Exercise" }
            return DisplayName.of(library.exercise(id)?.name ?? id)
        }

        func routine(_ ref: String?, in state: PlanState) -> Routine? {
            guard let ref, let id = UUID(uuidString: ref) else { return nil }
            return state.routines.first { $0.id == id }
        }

        /// The routine's current name, or the name a proposal's own `add-routine` gives it.
        func routineName(_ ref: String?, in state: PlanState) -> String {
            if let routine = routine(ref, in: state) { return routine.name }
            let added = changes.first { $0.type == .addRoutine && $0.routineId == ref }?.name
            return added?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ref ?? "Routine"
        }

        func item(in state: PlanState, _ exerciseId: String? = nil) -> RoutineExercise? {
            let id = exerciseId ?? change.exerciseId
            return routine(change.routineId, in: state)?.exercises.first { $0.exerciseId == id }
        }

        // MARK: Families

        private var name: String { exerciseName(change.exerciseId) }

        private var exerciseEditText: String {
            let place = routineName(change.routineId, in: before)
            switch change.type {
            case .addExercise:
                let added = item(in: after).map { prescription($0, unit: unit) }
                    ?? "\(change.sets ?? 0) \u{00D7} \(change.reps ?? 0)"
                return "\(name): \(added)\(arrow)added to \(place)"
            case .removeExercise: return "\(name)\(dash)removed from \(place)"
            case .swapExercise: return name + arrow + exerciseName(change.toExerciseId)
            case .reorder: return "\(name)\(arrow)#\((change.position ?? 0) + 1) in \(place)"
            default: return name + " + " + exerciseName(change.withExerciseId)
            }
        }

        private var valueText: String {
            if let old = item(in: before), let new = item(in: after) {
                return "\(name): \(prescription(old, unit: unit))\(arrow)\(prescription(new, unit: unit))"
            }
            return "\(name): \(fallbackValue)"
        }

        /// What the change sets, for a change that can't be shown against the plan.
        private var fallbackValue: String {
            switch change.type {
            case .sets: "\(change.sets ?? 0) sets"
            case .reps: "\(change.reps ?? 0) reps"
            case .repsMin: "at least \(change.repsMin ?? 0) reps"
            case .sec: "\(change.sec ?? 0) s"
            case .weight: weight(change.weightKg ?? 0, unit)
            default: "\(Int(change.minutes ?? 0)) min"
            }
        }

        private var progressionText: String {
            switch change.type {
            case .routineProg:
                let old = routine(change.routineId, in: before).map { policyName($0.policy) } ?? "Default"
                return "\(routineName(change.routineId, in: before)): \(old)\(arrow)\(policyName(change.policy ?? .off))"
            case .exerciseProg:
                let routinePolicy = routine(change.routineId, in: before)?.policy ?? .double
                let old = policyName(item(in: before)?.policy ?? routinePolicy)
                return "\(name): \(old)\(arrow)\(policyName(change.policy ?? .off))"
            default:
                let old = item(in: before)?.incKg.map { "+" + weight($0, unit) } ?? "Default"
                return "\(name): \(old)\(arrow)+\(weight(change.incKg ?? 0, unit))"
            }
        }

        private var routineText: String {
            let current = routineName(change.routineId, in: before)
            switch change.type {
            case .addRoutine: return routineName(change.routineId, in: after)
            case .removeRoutine: return "\(current)\(dash)routine removed"
            case .renameRoutine: return current + arrow + (change.name ?? "").trimmingCharacters(in: .whitespaces)
            case .pauseRoutine: return "\(current)\(dash)\(change.paused == false ? "resumed" : "paused")"
            default:
                let day = change.weekday ?? 0
                let old = before.schedule[day].flatMap { id in before.routines.first { $0.id == id }?.name } ?? "Rest"
                let new = change.routineId.map { routineName($0, in: after) } ?? "Rest"
                return "\(dayName(day)): \(old)\(arrow)\(new)"
            }
        }

        /// "Today (Sat 3 Oct): Home · KB Upper instead of Push + Arms" — against the routine scheduled that weekday.
        private var todayText: String {
            let new = routineName(change.routineId, in: after)
            guard let date = change.date, let number = PlanDay.number(date) else { return new }
            let title = dayTitle(date, today: today)
            let scheduled = after.schedule[isoWeekday(dayNumber: number)]
                .flatMap { id in after.routines.first { $0.id == id && !$0.paused } }
            guard let scheduled else { return "\(title): \(new) instead of a rest day" }
            if scheduled.id == routine(change.routineId, in: after)?.id { return "\(title): \(new) (as scheduled)" }
            return "\(title): \(new) instead of \(scheduled.name)"
        }
    }
}
