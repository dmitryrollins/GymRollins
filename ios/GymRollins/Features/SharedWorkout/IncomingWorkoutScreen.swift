import Foundation
import GymCore
import GymData

/// What opening a workout link shows (spec sections 5 and 7). Pure: everything it needs is passed in.
enum IncomingWorkoutScreen: Equatable {
    case preview(Preview)
    case damaged
    case tooNew
    case workoutRunning

    struct Preview: Equatable {
        /// What Use for today applies.
        let plan: TodayPlan
        let countText: String
        let rows: [Row]
        let droppedNotice: String?
        let replacesToday: Bool
        /// The person's own limits (Profile), shown above the rows: a link is the one way an exercise can arrive unfiltered.
        let limits: String?
    }

    struct Row: Equatable, Identifiable {
        /// The same row Today will show, in this person's weights and units.
        let row: TodayModel.Row
        let note: String?
        var id: UUID { row.id }
    }

    private static let bodyweightEquipment = "body weight"

    static func make(url: URL, link: WorkoutLink, library: ExerciseLibrary, profile: Profile, day: String,
                     isWorkoutRunning: Bool, currentPlan: () -> TodayPlan?, routines: [Routine],
                     preference: (String) -> ExercisePreference, history: (String) -> [SessionResult],
                     gym: TodayGymContext?) -> IncomingWorkoutScreen {
        guard let payload = link.payload(in: url) else { return .damaged }
        switch SharedWorkout.decode(payload, isKnown: { library.exercise($0) != nil }) {
        case .damaged:
            return .damaged
        case .tooNew:
            return .tooNew
        case let .valid(workout, dropped):
            if isWorkoutRunning { return .workoutRunning }
            let items = workout.routineItems { library.exercise($0)?.mode }.map { item in
                item.with(fixedWeightKg: ownWeight(exerciseId: item.exerciseId, routines: routines, library: library,
                                                   profile: profile, history: history(item.exerciseId)))
            }
            let plan = TodayPlan.shared(items: items, day: day)
            let model = TodayModel.make(plan: plan, profile: profile, library: library, history: history, gym: gym,
                                        loads: { gym?.loads(for: $0) })
            let rows = model.rows.map { Row(row: $0, note: note(for: $0, exercise: library.exercise($0.exerciseId),
                                                       preference: preference($0.exerciseId))) }
            return .preview(Preview(plan: plan, countText: count(rows.count), rows: rows,
                                    droppedNotice: droppedNotice(dropped), replacesToday: replacesSomething(currentPlan()),
                                    limits: profile.limits.isEmpty ? nil : profile.limits))
        }
    }

    /// This person's weight for `exerciseId`: what their own routine would suggest, else what they last lifted, else none.
    /// The sender's sets and reps never reach it.
    private static func ownWeight(exerciseId: String, routines: [Routine], library: ExerciseLibrary, profile: Profile,
                                  history: [SessionResult]) -> Double {
        let candidates = routines.flatMap { routine in
            routine.exercises.filter { $0.exerciseId == exerciseId }.map { (routine: routine, item: $0) }
        }
        let chosen = candidates.max { ($0.item.weightSetAt ?? .distantPast) < ($1.item.weightSetAt ?? .distantPast) }
        let best = chosen?.item.weightSetAt != nil ? chosen : (candidates.first { $0.item.weightKg != nil } ?? candidates.first)
        guard let best else { return max(0, history.first?.weightKg ?? 0) }
        let suggestion = SessionPlanner.suggestion(for: best.item, policy: best.item.policy ?? best.routine.policy,
                                                   profile: profile, exercise: library.exercise(exerciseId),
                                                   history: history)
        return max(0, suggestion.weightKg)
    }

    private static func count(_ count: Int) -> String { count == 1 ? "1 exercise" : "\(count) exercises" }

    private static func note(for row: TodayModel.Row, exercise: Exercise?, preference: ExercisePreference) -> String? {
        let avoided = preference == .never ? "You marked this \"Don't recommend\"" : nil
        let needsWeight = (row.suggestedKg ?? 0) == 0 && exercise?.mode == .reps
            && exercise?.equipment != bodyweightEquipment ? "Set on first set" : nil
        let parts = [avoided, needsWeight].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    private static func droppedNotice(_ dropped: Int) -> String? {
        switch dropped {
        case 0: nil
        case 1: "1 exercise isn't in your version of the app."
        default: "\(dropped) exercises aren't in your version of the app."
        }
    }

    /// Decision 3: only when something would be lost. A plain plan comes back by itself.
    private static func replacesSomething(_ plan: TodayPlan?) -> Bool {
        guard let plan, !plan.exercises.isEmpty else { return false }
        return plan.edited || !plan.setOverrides.isEmpty || plan.restSec != nil || plan.kind == .switched
            || plan.kind == .built
    }
}
