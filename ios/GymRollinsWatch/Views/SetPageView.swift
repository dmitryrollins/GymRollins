import GymWatchLink
import SwiftUI

/// The next set: weight and reps (tap one, then turn the Digital Crown — weight moves by the phone's plate/dumbbell
/// increment), Log set, and the rest countdown with +30s / Skip while resting.
struct SetPageView: View {
    @Environment(WatchAppModel.self) private var app
    let workout: WatchWorkout

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let rest = app.workout.runningRest { RestBanner(rest: rest) }
                if let next = workout.next {
                    Text(next.exerciseName).font(.headline).lineLimit(2)
                    Text(next.setLabel).font(.footnote).foregroundStyle(.secondary)
                    if next.canLog {
                        SetEditor(next: next)
                    } else {
                        Text(next.setDetail).font(.title3.weight(.semibold))
                        Text("Log this set on your iPhone.").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text(workout.status).font(.headline)
                    Text("Finish the workout on your iPhone.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Weight × reps with the Digital Crown, and Log set.
struct SetEditor: View {
    enum Field: Hashable { case weight, reps }

    @Environment(WatchAppModel.self) private var app
    let next: WatchNextSet
    /// Which value the crown changes.
    @State private var field = Field.weight
    @FocusState private var crownFocused: Bool
    @State private var crown = 0.0
    @State private var lastDetent = 0

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                value(WatchFormat.weight(app.workout.weight ?? next.weight), unit: next.grid.unit.rawValue, field: .weight)
                Text("\u{00D7}").foregroundStyle(.secondary)
                value("\(app.workout.reps ?? next.reps)", unit: "reps", field: .reps)
            }
            .focusable()
            .focused($crownFocused)
            .digitalCrownRotation($crown, from: -10_000, through: 10_000, by: 1, sensitivity: .medium,
                                  isContinuous: true, isHapticFeedbackEnabled: true)
            .onChange(of: crown) { _, value in turn(to: value) }
            Button {
                app.workout.logSet()
            } label: {
                Text(app.workout.isLogging ? "Logging…" : "Log set").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(WatchTheme.accent)
            .disabled(app.workout.isLogging)
        }
        .onAppear { crownFocused = true }
    }

    private func value(_ text: String, unit: String, field: Field) -> some View {
        Button {
            self.field = field
            crownFocused = true
        } label: {
            VStack(spacing: 0) {
                Text(text).font(.system(.title3, design: .rounded).monospacedDigit().weight(.bold))
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8)
                .stroke(self.field == field ? WatchTheme.accent : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(field == .weight ? "Weight \(text) \(unit)" : "\(text) reps")
        .accessibilityHint("Turn the Digital Crown to change")
    }

    /// One crown detent = one grid step (weight) or one rep.
    private func turn(to value: Double) {
        let detent = Int(value.rounded())
        let steps = detent - lastDetent
        guard steps != 0 else { return }
        lastDetent = detent
        switch field {
        case .weight: app.workout.stepWeight(by: steps)
        case .reps: app.workout.stepReps(by: steps)
        }
    }
}

/// The phone's rest: countdown, +30s, Skip.
struct RestBanner: View {
    @Environment(WatchAppModel.self) private var app
    let rest: WatchRest

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Rest").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text(timerInterval: Date()...max(Date(), rest.endsAt), countsDown: true)
                    .font(.system(.title2, design: .rounded).monospacedDigit().weight(.bold))
                    .foregroundStyle(WatchTheme.accent)
            }
            HStack {
                Button("+30s") { app.workout.addRest() }
                Button("Skip") { app.workout.skipRest() }
            }
            .font(.footnote)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
    }
}
