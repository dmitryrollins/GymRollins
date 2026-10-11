import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Lock-screen banner: exercise and next set on the left, the rest countdown on the right, buttons below.
struct WorkoutLockScreenView: View {
    let context: WorkoutActivityDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ExerciseHeadline(display: context, nameSize: 24)
                Spacer(minLength: 8)
                RestCountdown(display: context, size: 34)
            }
            if let rest = context.rest {
                ProgressView(timerInterval: rest, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .accessibilityHidden(true)
            }
            ActivityButtons(display: context)
        }
        .padding(16)
    }
}

/// Exercise name in the display face, then "Set 3/5 · 60 kg × 8".
struct ExerciseHeadline: View {
    let display: WorkoutActivityDisplay
    let nameSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(display.state.exerciseName)
                .font(Theme.display(nameSize))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(display.setLine)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// "RESTING 1:24" counting down on its own, or READY / REST OVER / DONE.
struct RestCountdown: View {
    let display: WorkoutActivityDisplay
    let size: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let rest = display.rest {
                Text("RESTING").font(.caption2.weight(.bold)).kerning(0.8).foregroundStyle(Theme.textSecondary)
                Text(timerInterval: rest, countsDown: true)
                    .font(Theme.display(size))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: size * 2.6, alignment: .trailing)
            } else {
                Text(display.idleWord)
                    .font(Theme.display(size * 0.6))
                    .foregroundStyle(display.state.isComplete ? Theme.success : Theme.textPrimary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Log set (reps-based exercises only), +30s and Skip (only while resting).
struct ActivityButtons: View {
    let display: WorkoutActivityDisplay

    var body: some View {
        let workoutId = display.attributes.workoutId
        HStack(spacing: 8) {
            if display.state.canLogSet, let entryId = display.state.entryId, let setId = display.state.setId {
                Button(intent: LogPlannedSetIntent(workoutId: workoutId, entryId: entryId, setId: setId)) {
                    Label("Log set", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.primaryFill)
            }
            if display.rest != nil {
                Button(intent: ExtendRestIntent(workoutId: workoutId, entryId: display.state.entryId)) {
                    Text("+30s").frame(minWidth: 44)
                }
                .buttonStyle(.bordered)
                .tint(Theme.textPrimary)
                .accessibilityLabel("Add 30 seconds of rest")
                Button(intent: SkipRestIntent(workoutId: workoutId, entryId: display.state.entryId)) {
                    Text("Skip").frame(minWidth: 44)
                }
                .buttonStyle(.bordered)
                .tint(Theme.textPrimary)
                .accessibilityLabel("Skip rest")
            }
        }
        .font(.subheadline.weight(.bold))
        .buttonBorderShape(.capsule)
    }
}

/// Dynamic Island compact trailing: the countdown while resting, otherwise the set ("3/5").
struct CompactStatus: View {
    let display: WorkoutActivityDisplay

    var body: some View {
        if let rest = display.rest {
            Text(timerInterval: rest, countsDown: true)
                .monospacedDigit()
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: 44)
        } else {
            Text(shortSet)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var shortSet: String {
        if display.state.isComplete { return "Done" }
        return display.state.setLabel.split(separator: " ").last.map(String.init) ?? ""
    }
}

/// Dynamic Island minimal: a countdown ring while resting, otherwise the dumbbell.
struct MinimalStatus: View {
    let display: WorkoutActivityDisplay

    var body: some View {
        if let rest = display.rest {
            ProgressView(timerInterval: rest, countsDown: true) { EmptyView() } currentValueLabel: {
                Image(systemName: "timer").font(.caption2)
            }
            .progressViewStyle(.circular)
            .tint(Theme.accent)
        } else {
            Image(systemName: "dumbbell.fill")
                .foregroundStyle(Theme.accent)
                .accessibilityLabel(display.state.exerciseName)
        }
    }
}
