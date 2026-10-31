import GymSync
import SwiftUI

/// "Sign in to share": the existing Sign in with Apple button, asked for when a share, a confirmation or a sync needs
/// an account. Cancelling it does nothing: the caller continues only through `onSignedIn`.
struct SignInForSharingSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onSignedIn: () -> Void
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                DisplayTitle(text: "Sign in to share", size: 32).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("signInForSharing.title")
                Text("Your gym's equipment stays yours until you share it. Nothing else leaves your phone.")
                    .foregroundStyle(Theme.textSecondary).accessibilityIdentifier("signInForSharing.body")
                AppleSignInButton(onToken: { token, nonce in signIn(token, nonce) }, onError: { error = $0 })
                    .disabled(busy)
                if let error {
                    Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("signInForSharing.error")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.gutter).padding(.top, 16)
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("signInForSharing.cancel")
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func signIn(_ token: String, _ nonce: String) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await env.sync.signInWithApple(idToken: token, nonce: nonce) } catch {
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
            onSignedIn()
        }
    }
}

extension View {
    /// Presents the sign-in sheet. `onSignedIn` runs only after a successful sign-in; closing the sheet any other way
    /// runs nothing.
    func signInForSharing(isPresented: Binding<Bool>, onSignedIn: @escaping () -> Void) -> some View {
        sheet(isPresented: isPresented) {
            SignInForSharingSheet {
                onSignedIn()
                isPresented.wrappedValue = false
            }
        }
    }
}
