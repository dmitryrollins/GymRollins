import Foundation
import GymCore
import SwiftUI

/// When the finished workout ends: now, or at the last set (+ rest) offered by `IdleFinish`.
enum FinishEnd: Equatable {
    case now
    case at(Date)

    /// The end to pass to `WorkoutSession.finish`; nil means now.
    var date: Date? {
        if case .at(let date) = self { return date }
        return nil
    }
}

/// Shown before saving when the last set was long ago (the owner forgot to tap Finish): ending at the last set keeps
/// the idle time out of the duration, calories and Apple Health. Used on its own (every set done) and as
/// `FinishSheet`'s first step (sets still undone).
struct IdleFinishPrompt: View {
    /// How long ago the last set was logged.
    let idleSeconds: TimeInterval
    let suggestedEnd: Date
    let onChoose: (FinishEnd) -> Void
    let onKeepGoing: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                DisplayTitle(text: "Finish workout?", size: 28)
                Text("Your last set was \(DurationFormatter.hoursMinutes(idleSeconds)) ago")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("finish.idleMessage")
                Text("Ending then keeps the waiting time out of your duration, calories and Apple Health.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                PrimaryGlassButton(title: "End at \(suggestedEnd.formatted(date: .omitted, time: .shortened))",
                                   identifier: "finish.endAtLastSet") { onChoose(.at(suggestedEnd)) }
                GlassPillButton(title: "End now", identifier: "finish.endNow") { onChoose(.now) }
                GlassPillButton(title: "Keep going", identifier: "finish.keepGoing", action: onKeepGoing)
            }
        }
    }
}
