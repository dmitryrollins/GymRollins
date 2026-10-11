import ActivityKit
import Foundation

/// `WorkoutActivityClient` over ActivityKit. Local-only activities (no push token): the app updates them itself, and
/// the rest countdown ticks in the widget on its own. `staleDate` is the rest's end, so the widget can show "Rest over"
/// without an update.
@MainActor
final class ActivityKitClient: WorkoutActivityClient {
    struct ActivitiesDisabled: LocalizedError {
        var errorDescription: String? { "Live Activities are turned off for GymRollins" }
    }

    func running() -> [RunningWorkoutActivity] {
        Activity<WorkoutActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
            .map { RunningWorkoutActivity(id: $0.id, workoutId: $0.attributes.workoutId) }
    }

    func start(_ attributes: WorkoutActivityAttributes, state: WorkoutActivityAttributes.ContentState) throws -> String {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw ActivitiesDisabled() }
        return try Activity.request(attributes: attributes, content: Self.content(state), pushType: nil).id
    }

    // Nonisolated: `Activity` isn't Sendable, so it is looked up and used in the same (nonisolated) context.
    nonisolated func update(id: String, state: WorkoutActivityAttributes.ContentState) async {
        await Self.activity(id)?.update(Self.content(state))
    }

    nonisolated func end(id: String) async {
        await Self.activity(id)?.end(nil, dismissalPolicy: .immediate)
    }

    private nonisolated static func activity(_ id: String) -> Activity<WorkoutActivityAttributes>? {
        Activity<WorkoutActivityAttributes>.activities.first { $0.id == id }
    }

    private nonisolated static func content(_ state: WorkoutActivityAttributes.ContentState)
        -> ActivityContent<WorkoutActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: state.restEndsAt)
    }
}
