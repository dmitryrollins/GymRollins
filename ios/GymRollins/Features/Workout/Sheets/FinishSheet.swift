import Foundation
import GymCore
import SwiftUI

/// Presented from "Finish" when the workout has undone sets. Offers discarding the empty sets,
/// marking everything done, going back, or discarding the whole workout. When the last set was long
/// ago (`suggestedEnd`), asks first whether the workout ends then or now (`IdleFinishPrompt`).
struct FinishSheet: View {
    @Bindable var session: WorkoutSession
    /// `IdleFinish`'s earlier end, worked out when Finish was tapped; nil asks nothing.
    var suggestedEnd: Date?
    let onFinished: (WorkoutSummary) -> Void
    let onDiscarded: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var showDiscardConfirm = false
    @State private var errorMessage: String?
    /// The owner's answer to the idle prompt (nil: not asked yet, or nothing to ask).
    @State private var end: FinishEnd?

    var body: some View {
        VStack(spacing: 18) {
            Capsule().fill(Color.white.opacity(0.3)).frame(width: 40, height: 5)
            if let suggestedEnd, end == nil {
                IdleFinishPrompt(idleSeconds: idleSeconds, suggestedEnd: suggestedEnd,
                                 onChoose: { end = $0 }, onKeepGoing: { dismiss() })
            } else {
                choices
            }
        }
        .padding(22)
        .presentationDetents([.medium])
        .confirmationDialog("Discard this workout? This can't be undone.", isPresented: $showDiscardConfirm,
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                if session.discardWorkout() {
                    errorMessage = nil
                    onDiscarded()
                } else {
                    errorMessage = "Couldn't discard the workout. Try again."
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var choices: some View {
        VStack(spacing: 8) {
            DisplayTitle(text: "Finish workout?", size: 28)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 6) {
                Image(systemName: "timer")
                Text("Workout time \(DurationFormatter.clock(session.duration(endingAt: end?.date ?? env.now())))")
            }
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
        }
        if let errorMessage {
            Text(errorMessage).font(.footnote).foregroundStyle(Theme.destructive)
                .accessibilityIdentifier("finish.error")
        }
        VStack(spacing: 10) {
            PrimaryGlassButton(title: "Finish and discard empty sets", identifier: "finish.discardEmpty") {
                finish(discardingUndone: true)
            }
            GlassPillButton(title: "Mark all as done", identifier: "finish.markAll") {
                session.markAllDone(at: end?.date)
                finish(discardingUndone: false)
            }
            GlassPillButton(title: "Keep going", identifier: "finish.keepGoing") { dismiss() }
        }
        Button("Discard workout") { showDiscardConfirm = true }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.destructive)
            .accessibilityIdentifier("finish.discard")
    }

    private var idleSeconds: TimeInterval {
        session.lastSetAt.map { env.now().timeIntervalSince($0) } ?? 0
    }

    private var message: String {
        let names = session.workout.entriesWithUndoneSets.map { entry in
            DisplayName.of(env.library.exercise(entry.exerciseId)?.name ?? entry.exerciseId)
        }
        let count = session.workout.undoneSetCount
        let joined = ListFormatter.localizedString(byJoining: names)
        return "\(count) set\(count == 1 ? "" : "s") not done in \(joined)."
    }

    private func finish(discardingUndone: Bool) {
        do {
            let summary = try session.finish(discardingUndone: discardingUndone, endingAt: end?.date)
            errorMessage = nil
            onFinished(summary)
        } catch {
            errorMessage = "Couldn't finish the workout. Try again."
        }
    }
}
