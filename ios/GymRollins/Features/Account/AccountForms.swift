import SwiftUI

#if DEBUG
/// DEBUG-only email/password sign-in for UI tests against the local stack (release builds use Apple only).
struct EmailSignInSection: View {
    let busy: Bool
    let signIn: (_ email: String, _ password: String) -> Void
    let signUp: (_ email: String, _ password: String) -> Void
    @State private var email = ""
    @State private var password = ""

    private var valid: Bool {
        email.contains("@") && password.count >= 6
    }

    var body: some View {
        Section("Email (debug builds)") {
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("account.email")
            // A plain field on purpose: this form only exists in DEBUG builds for UI tests against the local
            // stack, and SecureField drops XCUITest keystrokes when the Passwords AutoFill bar takes focus.
            TextField("Password", text: $password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("account.password")
            Button("Sign In") { signIn(trimmedEmail, password) }
                .disabled(!valid || busy)
                .accessibilityIdentifier("account.signIn")
            Button("Create Account") { signUp(trimmedEmail, password) }
                .disabled(!valid || busy)
                .accessibilityIdentifier("account.signUp")
        }
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
}
#endif

/// Second step of account deletion (or, signed out, erasing this iPhone's local copy): the owner types DELETE to
/// confirm. `message`/`confirmTitle`/`navigationTitle` differ between the two callers (`AccountSection`'s signed-in
/// delete and `SettingsView`'s signed-out "Erase all data").
struct DeleteAccountSheet: View {
    static let confirmationWord = "DELETE"
    var message = "Your workouts, plan, weigh-ins and profile will be deleted from your account and this iPhone."
    var confirmTitle = "Delete Account and Data"
    var navigationTitle = "Delete Account"
    var identifierPrefix = "account.delete"
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(message).foregroundStyle(Theme.textSecondary)
                    TextField("Type \(Self.confirmationWord) to confirm", text: $typed)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("\(identifierPrefix).field")
                }
                Section {
                    Button(confirmTitle, role: .destructive) {
                        dismiss()
                        onConfirm()
                    }
                    .disabled(typed != Self.confirmationWord)
                    .accessibilityIdentifier("\(identifierPrefix).confirm")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
