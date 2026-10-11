import Foundation

/// Which way the Apple Watch moves the shown exercise.
enum ExerciseStep: Equatable, Sendable {
    case previous, next
}

/// What a Live Activity button (or an Apple Watch action, plan 17) asks the app to do. Every case names the workout it
/// was rendered for, so a leftover activity or a queued watch tap can never act on a different workout.
enum WorkoutActivityAction: Equatable, Sendable {
    /// Log the next set of `entryId` with its planned values, only if `setId` is still that next set.
    case logPlannedSet(workoutId: UUID, entryId: UUID, setId: UUID)
    /// Like `logPlannedSet`, with the weight and reps adjusted on the watch (Digital Crown).
    case logSet(workoutId: UUID, entryId: UUID, setId: UUID, weightKg: Double, reps: Int)
    /// Show the exercise before/after `fromEntryId`, only while that is the exercise shown (the watch's buttons).
    case showExercise(workoutId: UUID, fromEntryId: UUID, step: ExerciseStep)
    /// Add `seconds` to the running rest. `entryId` is the exercise the activity shows, so a relaunched app (whose
    /// current entry resets to the first with undone sets) keeps showing it.
    case extendRest(workoutId: UUID, entryId: UUID?, seconds: TimeInterval)
    /// End the running rest now (`entryId` as for `extendRest`).
    case skipRest(workoutId: UUID, entryId: UUID?)

    var workoutId: UUID {
        switch self {
        case .logPlannedSet(let id, _, _), .logSet(let id, _, _, _, _), .showExercise(let id, _, _),
             .extendRest(let id, _, _), .skipRest(let id, _):
            id
        }
    }
}

/// Hands intent actions to the app. `LiveActivityIntent`s run in the app's process (the system launches it in the
/// background when needed), where `GymRollinsApp` installs `handler`; the widget extension compiles the intents only to
/// build its buttons and never performs them, so there the handler stays nil.
@MainActor
enum WorkoutActivityIntentRouter {
    static var handler: (@MainActor (WorkoutActivityAction) async -> Void)?

    static func perform(_ action: WorkoutActivityAction) async {
        guard let handler else { return }
        await handler(action)
    }
}
