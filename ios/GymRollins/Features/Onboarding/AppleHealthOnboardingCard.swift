import SwiftUI

/// Onboarding's optional Apple Health card (last step): connect now, or skip and turn it on later in Settings.
struct AppleHealthOnboardingCard: View {
    @Environment(AppEnvironment.self) private var env
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: "Apple Health (optional)")
            Text("Save workouts with estimated calories to Health, and bring in your weight from Health.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if env.health.isEnabled {
                Label("Connected to Apple Health", systemImage: "heart.fill")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.success)
                    .accessibilityIdentifier("onboarding.health.connected")
            } else {
                SecondaryGlassButton(title: working ? "Connecting\u{2026}" : "Connect Apple Health",
                                     identifier: "onboarding.health") {
                    guard !working else { return }
                    working = true
                    Task {
                        await env.health.enable()
                        working = false
                    }
                }
                Text("You can skip this and turn it on later in Settings \u{2192} Apple Health.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
    }
}
