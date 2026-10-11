import GymSync
import SwiftUI

/// First onboarding screen: hero, value prop, Sign in with Apple (real auth), a DEBUG-only email sheet, and
/// "Skip for now" (local-only; the user can sign in later from Settings). Any of the three proceeds to Profile
/// Setup.
struct WelcomeView: View {
    @Environment(AppEnvironment.self) private var env
    let onNext: () -> Void
    @State private var error: String?
    @State private var busy = false
    #if DEBUG
    @State private var showEmailSheet = false
    #endif

    var body: some View {
        VStack(spacing: 28) {
            hero
            VStack(spacing: 10) {
                DisplayTitle(text: "GymRollins", size: 46).accessibilityIdentifier("onboarding.welcome")
                Text("Log every set. Let Claude plan the next one.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actions
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 58)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .disabled(busy)
        #if DEBUG
        .sheet(isPresented: $showEmailSheet) { emailSheet }
        #endif
    }

    private var hero: some View {
        RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.card)
            // Flexible: the hero gives up height first, so the text and buttons below never get squeezed (clipped).
            .frame(minHeight: 120, maxHeight: 320)
            .overlay(Image(systemName: "dumbbell.fill").font(.system(size: 56)).foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true))
    }

    private var actions: some View {
        VStack(spacing: 16) {
            AppleSignInButton(onToken: { token, nonce in
                signIn { try await env.sync.signInWithApple(idToken: token, nonce: nonce) }
            }, onError: { error = $0 })
            #if DEBUG
            SecondaryGlassButton(title: "Continue with email", identifier: "onboarding.email") { showEmailSheet = true }
            #endif
            SecondaryGlassButton(title: "Skip for now", identifier: "onboarding.skip") { onNext() }
            if let error {
                Text(error).font(.footnote).foregroundStyle(Theme.destructive).accessibilityIdentifier("onboarding.error")
            }
        }
    }

    #if DEBUG
    private var emailSheet: some View {
        NavigationStack {
            Form {
                EmailSignInSection(busy: busy,
                                   signIn: { email, password in
                                       signIn { try await env.sync.signIn(email: email, password: password) }
                                   },
                                   signUp: { email, password in
                                       signIn { try await env.sync.signUp(email: email, password: password) }
                                   })
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showEmailSheet = false } } }
        }
    }
    #endif

    /// Runs a sign-in action; on success, closes the email sheet (if open) and advances to Profile Setup.
    private func signIn(_ action: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do {
                try await action()
                #if DEBUG
                showEmailSheet = false
                #endif
                onNext()
            } catch {
                AppEnvironment.log.error("Onboarding sign-in failed: \(String(describing: error), privacy: .public)")
                self.error = (error as? AuthFailure)?.message ?? "Something went wrong. Please try again."
            }
            busy = false
        }
    }
}
