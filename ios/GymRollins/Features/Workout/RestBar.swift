import SwiftUI

/// Haptic played when a rest runs out on its own (not when skipped), gated by the
/// "Sound + haptic when rest ends" preference.
enum RestFeedback {
    static func onRestCompleted(soundEnabled: Bool) -> SensoryFeedback? { soundEnabled ? .success : nil }
}

/// Floating glass rest bar that replaces the logging screen's primary action while resting:
/// −15s / +15s / remaining time / prominent Skip. `now` is the app's own clock (not the real
/// wall clock `TimelineView` ticks with), so this stays correct under a fixed/injected clock too.
struct RestBar: View {
    let rest: RestTimer
    let now: Date
    let onMinus: () -> Void
    let onPlus: () -> Void
    let onSkip: () -> Void

    var body: some View {
        // The remaining-time readout is the bar's accessibility element ("logging.rest"): VoiceOver reads
        // "Rest timer, 1 minute 45 seconds remaining". It is a sibling of the buttons, never their ancestor (on this
        // SDK a container's identifier overrides its identified descendants' own identifiers).
        HStack(spacing: 10) {
            circleButton(system: "minus", label: "Subtract 15 seconds", identifier: "logging.rest.minus", action: onMinus)
            VStack(spacing: 0) {
                // At accessibility sizes "RESTING" doesn't fit the middle column on one line; "REST" does.
                ViewThatFits(in: .horizontal) {
                    ForEach(["RESTING", "REST"], id: \.self) { word in
                        Text(word).font(.caption2.weight(.bold)).kerning(0.8).fixedSize()
                    }
                }
                .foregroundStyle(Theme.textSecondary)
                Text(rest.label(at: now)).font(Theme.display(24))
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rest timer")
            .accessibilityValue(RestAccessibilityText.value(remaining: remaining))
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("logging.rest")
            circleButton(system: "plus", label: "Add 15 seconds", identifier: "logging.rest.plus", action: onPlus)
            Button(action: onSkip) { Text("Skip").fixedSize() }
                .buttonStyle(.glassProminent)
                .tint(Theme.primaryFill)
                .accessibilityLabel("Skip rest")
                .accessibilityIdentifier("logging.rest.skip")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 60)
        .glassCapsule()
        .onChange(of: wholeSecondsRemaining) { old, new in
            if let text = RestAccessibilityText.announcement(from: old, to: new) {
                AccessibilityNotification.Announcement(text).post()
            }
        }
    }

    private var remaining: TimeInterval { rest.remaining(at: now) }
    private var wholeSecondsRemaining: Int { Int(remaining.rounded(.up)) }

    private func circleButton(system: String, label: String, identifier: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: system) }
            .glassCircle()
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }
}
