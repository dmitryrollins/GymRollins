import GymSync
import SwiftUI

/// "Sign in to share": the existing Sign in with Apple button, asked for when a share, a confirmation or a sync needs
/// an account. Cancelling it does nothing: the caller continues only through `onSignedIn`, and not at all once the
/// sheet has closed, even if the sign-in call was still running when the user cancelled.
struct SignInForSharingSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var purpose = SignInPurpose.share
    let onSignedIn: () -> Void
    @State private var error: String?
    @State private var busy = false
    @State private var isOpen = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DisplayTitle(text: purpose.title, size: 32).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("signInForSharing.title")
                    Text(purpose.body)
                        .foregroundStyle(Theme.textSecondary).accessibilityIdentifier("signInForSharing.body")
                    AppleSignInButton(onToken: { token, nonce in signIn(token, nonce) }, onError: { error = $0 })
                        .disabled(busy)
                    if let error {
                        Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("signInForSharing.error")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.gutter).padding(.top, 16)
            }
            .background(Theme.background)
            .onDisappear { isOpen = false }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("signInForSharing.cancel")
                }
            }
        }
    }

    private func signIn(_ token: String, _ nonce: String) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await env.sync.signInWithApple(idToken: token, nonce: nonce, waitingForSync: false) } catch {
                AppEnvironment.log.error("Sign in for sharing failed: \(String(describing: error), privacy: .public)")
                self.error = (error as? AuthFailure)?.message ?? "Something went wrong. Please try again."
                return
            }
            guard env.sharingUserId != nil else {
                error = env.sync.accountSwitchPending
                    ? "This phone has data from another account. Finish signing in from Account first."
                    : "Couldn't sign in. Please try again."
                return
            }
            guard isOpen else { return } // cancelled while signing in: the account stays signed in, the action is dropped
            onSignedIn()
        }
    }
}

extension View {
    /// Presents the sign-in sheet. `onSignedIn` runs only after a successful sign-in; closing the sheet any other way
    /// runs nothing.
    func signInForSharing(isPresented: Binding<Bool>, purpose: SignInPurpose = .share,
                          onSignedIn: @escaping () -> Void) -> some View {
        sheet(isPresented: isPresented) {
            SignInForSharingSheet(purpose: purpose) {
                onSignedIn()
                isPresented.wrappedValue = false
            }
        }
    }
}
