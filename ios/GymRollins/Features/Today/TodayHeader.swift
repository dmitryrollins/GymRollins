import SwiftUI

/// The top of Today in a contacts-app style (2026-11-18): Settings on the left, the day's workout in a
/// wide pill whose ⌄ switches it, and My Plan and the day picker sharing one pill on the right. At accessibility sizes
/// the workout pill takes its own row under the other two.
struct TodayHeader: View {
    struct Actions {
        let settings: () -> Void
        let switchWorkout: () -> Void
        let plan: () -> Void
        let pickDay: () -> Void
        let nextDay: () -> Void
        let previousDay: () -> Void
    }

    /// The workout's name, and what it is ("7 exercises · edited for today"): VoiceOver reads it all, the pill shows
    /// only the day and the number of exercises (owner, 2026-11-19: only what matters at a glance).
    let workout: String
    let summary: String
    let exercises: Int
    /// The day shown: "Today", "Tomorrow", "Monday".
    let day: String
    let date: Date
    /// False while a workout runs or there's nothing to switch to: the pill shows the workout without the ⌄.
    let canSwitch: Bool
    /// False while a workout runs: Today stays on today.
    let canPickDay: Bool
    let actions: Actions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                HStack {
                    settingsButton
                    Spacer()
                    dayButtons
                }
                workoutPill
            }
        } else {
            HStack(spacing: 8) {
                settingsButton
                workoutPill
                dayButtons
            }
        }
    }

    private var settingsButton: some View {
        SettingsCircle(identifier: "today.settings", action: actions.settings)
    }

    /// VoiceOver reads the workout and what it is, then the day; tests find it as `today.workout`.
    @ViewBuilder
    private var workoutPill: some View {
        if canSwitch {
            Button(action: actions.switchWorkout) { pillLabel }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityLabel("\(workout) \u{00B7} \(summary)")
                .accessibilityValue(day)
                .accessibilityHint("Pick another workout for this day")
                .accessibilityIdentifier("today.workout")
        } else {
            pillLabel
                .glassEffect(.regular, in: .capsule)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(workout) \u{00B7} \(summary)")
                .accessibilityValue(day)
                .accessibilityIdentifier("today.workout")
        }
    }

    /// Like the reference, the name keeps to one line (shrinking a little first; a long one ends in "…", VoiceOver reads
    /// it all) and what it is takes a second line only when it's long. At accessibility sizes both wrap.
    private var pillLabel: some View {
        let large = dynamicTypeSize.isAccessibilitySize
        return HStack(spacing: 8) {
            VStack(spacing: 1) {
                Text(workout).font(.headline).foregroundStyle(Theme.textPrimary)
                    .lineLimit(large ? 3 : 1)
                    .minimumScaleFactor(large ? 1 : 0.7)
                Text(Self.subtitle(day: day, exercises: exercises)).font(.footnote).foregroundStyle(Theme.textSecondary)
                    .lineLimit(large ? 3 : 2)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            if canSwitch {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, canSwitch ? 12 : 14)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: Theme.minTapSize)
        .contentShape(.capsule)
    }

    /// "Today · 7 exercises", or just the day when there's nothing to do. When it wraps it breaks only between the
    /// parts: "Today ·" over "7 exercises", never "Today · 7" over "exercises".
    nonisolated static func subtitle(day: String, exercises: Int) -> String {
        let count = exercises == 1 ? "1 exercise" : "\(exercises) exercises"
        return (exercises > 0 ? [day, count] : [day])
            .map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }
            .joined(separator: " \u{00B7} ")
    }

    /// My Plan and the day picker, one pill like the reference's compose and search.
    private var dayButtons: some View {
        HeaderButtons {
            Button(action: actions.plan) { HeaderIcon(systemName: "list.bullet") }
                .accessibilityLabel("My Plan")
                .accessibilityIdentifier("today.myPlan")
            Button(action: actions.pickDay) { HeaderIcon(systemName: "calendar", dimmed: !canPickDay) }
                .disabled(!canPickDay)
                .accessibilityLabel(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .accessibilityHint("Pick a day to see its workout")
                .accessibilityIdentifier("today.date")
                .accessibilityAction(named: "Next day", actions.nextDay)
                .accessibilityAction(named: "Previous day", actions.previousDay)
        }
    }
}
