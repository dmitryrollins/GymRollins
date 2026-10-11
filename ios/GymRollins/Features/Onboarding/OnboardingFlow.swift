import SwiftUI

/// Onboarding: Welcome -> Profile Setup -> Import CSV (which swaps in Import Result locally once a plan is built)
/// -> Connect Claude -> Today (`RootView` switches to the main tabs once `env.onboardingComplete` flips).
struct OnboardingFlow: View {
    private enum Step: Hashable { case profileSetup, importCSV, connectClaude }

    @Environment(AppEnvironment.self) private var env
    @State private var path: [Step] = []
    @State private var weighInId: UUID?

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView(onNext: { path.append(.profileSetup) })
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Step.self) { step in
                    destination(for: step)
                        .toolbar(.hidden, for: .navigationBar)
                        .navigationBarBackButtonHidden(true)
                }
        }
        .tint(Theme.accent)
    }

    @ViewBuilder
    private func destination(for step: Step) -> some View {
        switch step {
        case .profileSetup:
            ProfileSetupView(weighInId: $weighInId, onBack: pop, onContinue: { path.append(.importCSV) })
        case .importCSV:
            ImportCSVView(onBack: pop, onDone: { path.append(.connectClaude) })
        case .connectClaude:
            ConnectClaudeStepView(onBack: pop, onFinish: { useTemplate in env.completeOnboarding(useTemplate: useTemplate) })
        }
    }

    private func pop() {
        if !path.isEmpty { path.removeLast() }
    }
}
