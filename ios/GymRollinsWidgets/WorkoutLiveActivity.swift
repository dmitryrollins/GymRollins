import ActivityKit
import SwiftUI
import WidgetKit

/// Lock screen + Dynamic Island presentation of `WorkoutActivityAttributes`. The app computes every string; this only
/// lays them out. The rest countdown uses timer text, so it ticks without updates; once the rest's `staleDate` passes
/// the activity reads "Rest over".
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutLockScreenView(context: WorkoutActivityDisplay(context))
                .activityBackgroundTint(Theme.background)
                .activitySystemActionForegroundColor(Theme.textPrimary)
        } dynamicIsland: { context in
            let display = WorkoutActivityDisplay(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "dumbbell.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RestCountdown(display: display, size: 26)
                }
                DynamicIslandExpandedRegion(.center) {
                    ExerciseHeadline(display: display, nameSize: 20)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityButtons(display: display)
                }
            } compactLeading: {
                Image(systemName: "dumbbell.fill")
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel(display.state.exerciseName)
            } compactTrailing: {
                CompactStatus(display: display)
            } minimal: {
                MinimalStatus(display: display)
            }
            .keylineTint(Theme.accent)
        }
    }
}

/// The context values the views need, with the "resting" rule in one place.
struct WorkoutActivityDisplay {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    init(_ context: ActivityViewContext<WorkoutActivityAttributes>) {
        attributes = context.attributes
        state = context.state
        isStale = context.isStale
    }

    /// The running rest, nil when not resting or when it has run out (the activity went stale at its end).
    var rest: ClosedRange<Date>? {
        guard !isStale, let interval = state.restInterval, interval.upperBound > .now else { return nil }
        return interval
    }

    /// "Set 3/5 · 60 kg × 8".
    var setLine: String {
        [state.setLabel, state.setDetail].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Shown instead of the countdown when not resting.
    var idleWord: String {
        if state.isComplete { return "DONE" }
        return state.restInterval != nil ? "REST OVER" : "READY"
    }
}
