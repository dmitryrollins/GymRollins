import SwiftUI

/// Onboarding step 3/3: the same connector URL/steps as `ClaudeConnectionView` (via the shared
/// `ConnectorInstructions`), a consent preview, and "Done"/"Later" (both finish onboarding; the connector itself
/// is optional and can always be revisited from Settings).
struct ConnectClaudeStepView: View {
    @Environment(AppEnvironment.self) private var env
    let onBack: () -> Void
    /// `useTemplate` is true when the user chose the Push/Pull/Upper/Legs template for an empty plan.
    let onFinish: (_ useTemplate: Bool) -> Void

    @State private var copied = false
    @State private var showTemplateChoice = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel(text: "Step 3 of 3")
                    DisplayTitle(text: "Connect Claude", size: 34)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ConnectorInstructions(connectorURL: env.connectorURL, copied: $copied)
                    consentPreview
                }
                if env.health.isAvailable { AppleHealthOnboardingCard() }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 58)
            .padding(.bottom, 130)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                PrimaryGlassButton(title: "Done", identifier: "onboarding.done") { finish() }
                SecondaryGlassButton(title: "Later", identifier: "onboarding.later") { finish() }
            }
            .padding(.horizontal, Theme.gutter).padding(.bottom, 8)
        }
        .confirmationDialog("Set up your training split?", isPresented: $showTemplateChoice, titleVisibility: .visible) {
            Button("Use the Push / Pull / Upper / Legs template") { onFinish(true) }
                .accessibilityIdentifier("onboarding.template")
            Button("Start with an empty plan") { onFinish(false) }
                .accessibilityIdentifier("onboarding.template.empty")
        }
    }

    private var header: some View {
        HStack {
            OnboardingBackButton(action: onBack)
            Spacer()
            OnboardingProgressDots(step: 3)
        }
    }

    private var consentPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "Consent preview")
            Text("Allow Claude to access GymRollins").font(.subheadline.weight(.bold))
            Text("Read workouts & bodyweight \u{00B7} Propose plan changes")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
    }

    /// Offers the split template only when the plan is genuinely empty; otherwise finishes directly.
    private func finish() {
        if env.hasAnyRoutine {
            onFinish(false)
        } else {
            showTemplateChoice = true
        }
    }
}
