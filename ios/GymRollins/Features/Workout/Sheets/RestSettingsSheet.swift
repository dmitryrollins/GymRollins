import GymCore
import SwiftUI

/// Rest timer settings for the exercise screen: working vs. warm-up duration, and two global toggles (rest timer
/// on/off, sound + haptic). The working rest is the exercise's own, in every workout (`ExerciseRestStore`); the
/// warm-up rest is the running workout's (Today's plan screen has none: `warmup` is nil).
struct RestSettingsSheet: View {
    let working: Binding<TimeInterval>
    var warmup: Binding<TimeInterval>?
    /// Called when "Rest timer between sets" changes (the running session follows it at once).
    var onRestEnabled: (Bool) -> Void = { _ in }
    /// The working section's note.
    var footnote = "Rest between working sets."
    /// The exercise's suggested working rest: "Use suggested" shows while the working rest differs from it.
    var suggested: TimeInterval?
    @Environment(\.dismiss) private var dismiss
    @State private var section = 0
    @AppStorage(RestPreferences.enabledKey) private var restTimerEnabled = true
    @AppStorage(RestPreferences.soundKey) private var restSound = true

    /// Working sets: 0:30 to 15:00 (`DomainLimits.restSec`'s top). Warm-ups: 0:30 to 5:00.
    static let workingRange = 30...DomainLimits.restSec.upperBound
    static let warmupRange = 30...300
    static let warmupFootnote = "Warm-up rest for this workout."

    /// Short enough for the medium sheet: a longer note was cut off there.
    static func footnote(exerciseName: String) -> String {
        "\(exerciseName) keeps this rest in every workout."
    }

    /// Every 15 s in `range`, plus `current` when it's off that grid (a stored value keeps its row).
    static func options(in range: ClosedRange<Int>, including current: Int) -> [TimeInterval] {
        let grid = Set(stride(from: range.lowerBound, through: range.upperBound, by: 15))
        return grid.union([current]).sorted().map(TimeInterval.init)
    }

    var body: some View {
        VStack(spacing: 18) {
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
                ForEach(Self.options(in: isWarmup ? Self.warmupRange : Self.workingRange,
                                     including: Int(durationBinding.wrappedValue)), id: \.self) { seconds in
                    Text(DurationFormatter.clock(seconds)).tag(seconds)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 120)
            if !isWarmup, let suggested, Int(working.wrappedValue) != Int(suggested) {
                GlassPillButton(title: "Use suggested (\(DurationFormatter.clock(suggested)))",
                                identifier: "rest.useSuggested") { working.wrappedValue = suggested }
            }
            Toggle("Rest timer between sets", isOn: restEnabledBinding)
                .padding(12)
                .background(Theme.card, in: .rect(cornerRadius: 16))
            Toggle("Sound + haptic when rest ends", isOn: $restSound)
                .padding(12)
                .background(Theme.card, in: .rect(cornerRadius: 16))
            Text(isWarmup ? Self.warmupFootnote : footnote)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .presentationDetents([.medium, .large])
    }

    private var isWarmup: Bool { section == 1 && warmup != nil }

    private var durationBinding: Binding<TimeInterval> {
        if isWarmup, let warmup { return warmup }
        return working
    }

    private var restEnabledBinding: Binding<Bool> {
        Binding(get: { restTimerEnabled }, set: { restTimerEnabled = $0; onRestEnabled($0) })
    }
}

extension RestSettingsSheet {
    /// The exercise screen's rest sheet: the exercise's own working rest (both modes, suggested from the workout's or
    /// today's default) and, in a workout, the workout's warm-up rest.
    @MainActor
    init(model: ExerciseScreenModel, exercise: Exercise?) {
        let working = Binding(get: { model.restSeconds }, set: { model.setRestSeconds($0) })
        let footnote = Self.footnote(exerciseName: exercise.map { DisplayName.of($0.name) } ?? "This exercise")
        let suggested = TimeInterval(ExerciseRest.suggested(for: exercise, defaultSec: Int(model.defaultRestSeconds)))
        switch model {
        case .workout(let session, _):
            self.init(working: working,
                      warmup: Binding(get: { session.warmupRestSeconds }, set: { session.warmupRestSeconds = $0 }),
                      onRestEnabled: { session.restEnabled = $0 }, footnote: footnote, suggested: suggested)
        case .plan:
            self.init(working: working, footnote: footnote, suggested: suggested)
        }
    }
}
