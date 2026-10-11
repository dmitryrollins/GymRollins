import ActivityKit
import Foundation

/// The in-progress workout's Live Activity. Compiled into both the app and the widget extension (ActivityKit matches
/// the type across the two binaries), so it holds display-ready values only: the app computes them
/// (`WorkoutActivityContent`) and the extension just draws them.
struct WorkoutActivityAttributes: ActivityAttributes, Hashable {
    struct ContentState: Codable, Hashable, Sendable {
        /// "Barbell Bench Press", or the workout's name when there is no set left to show.
        var exerciseName: String
        /// "Set 3/5", "Warm-up 1/2", "All sets done".
        var setLabel: String
        /// The next planned set in the user's unit: "60 kg × 8", "45 s", "20 min · 3.1 mi"; empty when none.
        var setDetail: String
        /// The running rest, nil when not resting. `Text(timerInterval:)` counts it down without app updates.
        var restStartedAt: Date?
        var restEndsAt: Date?
        /// Whether the Log set button shows: reps-based exercise with a next set.
        var canLogSet: Bool
        /// The entry and set a Log set tap refers to (a tap on a stale activity is ignored by the app).
        var entryId: UUID?
        var setId: UUID?
        /// No undone set anywhere in the workout.
        var isComplete: Bool

        /// The rest interval for timer views, nil when not resting.
        var restInterval: ClosedRange<Date>? {
            guard let start = restStartedAt, let end = restEndsAt, start <= end else { return nil }
            return start...end
        }
    }

    /// `Workout.id`; every action carries it so a leftover activity can't act on a newer workout.
    let workoutId: UUID
    let workoutName: String
}
