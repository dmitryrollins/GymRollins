import GymCore
import SwiftUI

/// Rest timer settings for the exercise screen: working vs. warm-up duration, and two global toggles (rest timer
/// on/off, sound + haptic). In a workout it edits the session's rests; on Today's plan screen, today's rest (working
/// sets only: `warmup` is nil).
struct RestSettingsSheet: View {
    let working: Binding<TimeInterval>
    var warmup: Binding<TimeInterval>?
    /// Called when "Rest timer between sets" changes (the running session follows it at once).
    var onRestEnabled: (Bool) -> Void = { _ in }
    var footnote = "Default for this exercise; change all in Settings."
    @Environment(\.dismiss) private var dismiss
    @State private var section = 0
    @AppStorage(RestPreferences.enabledKey) private var restTimerEnabled = true
    @AppStorage(RestPreferences.soundKey) private var restSound = true

    /// The session's choices; today's rest (plan mode) offers everything a plan may hold (`DomainLimits.restSec`).
    var range: ClosedRange<Int> = 30...300

    /// Every 15 s in `range`, plus `current` when it's off that grid (a stored value keeps its row).
    static func options(in range: ClosedRange<Int>, including current: Int) -> [TimeInterval] {
        let grid = Set(stride(from: range.lowerBound, through: range.upperBound, by: 15))
        return grid.union([current]).sorted().map(TimeInterval.init)
    }

    var body: some View {
        VStack(spacing: 18) {
            Capsule().fill(Color.white.opacity(0.3)).frame(width: 40, height: 5)
            HStack {
                DisplayTitle(text: "Rest Timer", size: 28)
                Spacer()
                GlassPillButton(title: "Done", identifier: "rest.done") { dismiss() }
            }
            if warmup != nil {
                Picker("Section", selection: $section) {
                    Text("Working sets").tag(0)
                    Text("Warm-up sets").tag(1)
                }
                .pickerStyle(.segmented)
            }
            Picker("Rest duration", selection: durationBinding) {
                ForEach(Self.options(in: range, including: Int(durationBinding.wrappedValue)), id: \.self) { seconds in
                    Text(DurationFormatter.clock(seconds)).tag(seconds)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 120)
            Toggle("Rest timer between sets", isOn: restEnabledBinding)
                .padding(12)
                .background(Theme.card, in: .rect(cornerRadius: 16))
            Toggle("Sound + haptic when rest ends", isOn: $restSound)
                .padding(12)
                .background(Theme.card, in: .rect(cornerRadius: 16))
            Text(footnote)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(20)
        .presentationDetents([.medium, .large])
    }

    private var durationBinding: Binding<TimeInterval> {
        if section == 1, let warmup { return warmup }
        return working
    }

    private var restEnabledBinding: Binding<Bool> {
        Binding(get: { restTimerEnabled }, set: { restTimerEnabled = $0; onRestEnabled($0) })
    }
}

extension RestSettingsSheet {
    /// The exercise screen's rest sheet: the session's working and warm-up rests, or today's rest (plan mode).
    @MainActor
    init(model: ExerciseScreenModel) {
        let working = Binding(get: { model.restSeconds }, set: { model.setRestSeconds($0) })
        switch model {
        case .workout(let session, _):
            self.init(working: working,
                      warmup: Binding(get: { session.warmupRestSeconds }, set: { session.warmupRestSeconds = $0 }),
                      onRestEnabled: { session.restEnabled = $0 })
        case .plan:
            self.init(working: working, footnote: "Rest between sets for today's workout.",
                      range: DomainLimits.restSec)
        }
    }
}
