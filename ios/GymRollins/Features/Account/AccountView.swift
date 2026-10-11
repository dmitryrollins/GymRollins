import GymSync
import SwiftUI

/// Account and sync: sign in (Apple; email/password in DEBUG builds), then sync status, "Sync now", sign-out
/// (a last sync, then removes this iPhone's copy after confirmation — with an explicit warning listing unsynced
/// changes and an in-progress workout when there are any) and account deletion. Embedded as Settings' Account section
/// (no `Form`/navigation title of its own — the parent `SettingsView` provides those).
struct AccountSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var error: String?
    @State private var busy = false
    @State private var confirmSignOut = false
    /// Set when a last sync left something that signing out would delete: the owner picks what to do.
    @State private var signOutRisk: SignOutReport?

    var body: some View {
        Group {
            if !env.sync.isAvailable {
                Section {
                    Text("Sync is turned off in this build.").foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("account.unavailable")
                }
            } else if env.sync.accountSwitchPending {
                accountSwitch
            } else if case .signedIn(_, let email) = env.sync.authState {
                signedIn(email: email)
            } else {
                signedOut
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("account.error")
                }
            }
        }
        .disabled(busy)
        .confirmationDialog("Remove this iPhone's copy of your data? It stays in your account.",
                            isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out and Remove", role: .destructive) { run { try await env.sync.signOutAndRemoveLocalData() } }
                .accessibilityIdentifier("account.signOut.confirm")
        }
        .alert("Data will be lost", isPresented: Binding(get: { signOutRisk != nil },
                                                        set: { if !$0 { signOutRisk = nil } })) {
            Button("Sync and Sign Out") { run { try await syncThenSignOut() } }
                .accessibilityIdentifier("account.signOut.sync")
            Button("Sign Out Anyway", role: .destructive) { run { try await env.sync.signOutAndRemoveLocalData() } }
                .accessibilityIdentifier("account.signOut.anyway")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("account.signOut.cancel")
        } message: {
            Text(signOutRisk?.warning ?? "")
        }
    }

    /// A last sync first; the plain confirmation when nothing would be lost, otherwise the explicit warning.
    private func beginSignOut() {
        run {
            let report = await env.prepareSignOut()
            if report.isSafe { confirmSignOut = true } else { signOutRisk = report }
        }
    }

    /// Syncs again and signs out once nothing but the disclosed in-progress workout would be lost; otherwise the
    /// warning comes back with what's still not uploaded.
    private func syncThenSignOut() async throws {
        let report = await env.prepareSignOut()
        if report.unsynced == 0 && report.failed == 0 {
            try await env.sync.signOutAndRemoveLocalData()
        } else {
            signOutRisk = report
        }
    }

    // MARK: Signed in

    @ViewBuilder
    private func signedIn(email: String?) -> some View {
        Section("Signed in") {
            Text(email ?? "Apple ID").accessibilityIdentifier("account.emailLabel")
        }
        Section("Sync") {
            HStack {
                Text("Status")
                Spacer()
                Text(SyncStatusText.status(env.sync.status, pending: env.sync.pendingChanges,
                                           lastSyncedAt: env.sync.lastSyncedAt))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("account.status")
            }
            HStack {
                Text("Last synced")
                Spacer()
                Text(SyncStatusText.lastSynced(env.sync.lastSyncedAt, now: env.now()))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("account.lastSync")
            }
            Button("Sync Now") { Task { await env.sync.syncNow() } }
                .disabled(env.sync.status == .syncing)
                .accessibilityIdentifier("account.syncNow")
        }
        if !env.sync.syncFailures.isEmpty { failures }
        Section {
            Button("Sign Out") { beginSignOut() }
                .accessibilityIdentifier("account.signOut")
        }
    }

    /// Rows the server refused: a count plus what each one is and why.
    private var failures: some View {
        Section {
            DisclosureGroup {
                ForEach(env.sync.syncFailures, id: \.id) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SyncStatusText.entityName(failure.entity)).font(.subheadline.weight(.semibold))
                        Text(failure.message).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Text("Edit the item to try again.").font(.caption).foregroundStyle(Theme.textTertiary)
            } label: {
                Text(SyncStatusText.failures(env.sync.syncFailures.count))
                    .foregroundStyle(Theme.destructive)
                    .accessibilityIdentifier("account.syncFailures")
            }
        }
    }

    // MARK: Account switch

    /// Signed in to a different account than the one this iPhone's data belongs to.
    @ViewBuilder
    private var accountSwitch: some View {
        Section {
            Text("This iPhone has data from another account. Signing in will remove it from this iPhone.")
                .accessibilityIdentifier("account.switch.message")
            Button("Remove and Sign In", role: .destructive) {
                run { try await env.sync.confirmAccountSwitch() }
            }
            .accessibilityIdentifier("account.switch.confirm")
            Button("Cancel") { run { try await env.sync.cancelAccountSwitch() } }
                .accessibilityIdentifier("account.switch.cancel")
        } footer: {
            Text("The other account's data stays in that account. Only unsynced changes on this iPhone are lost.")
        }
    }

    // MARK: Signed out

    @ViewBuilder
    private var signedOut: some View {
        Section {
            AppleSignInButton(onToken: { token, nonce in
                run { try await env.sync.signInWithApple(idToken: token, nonce: nonce) }
            }, onError: { error = $0 })
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } header: {
            Text("Sign in to back up your workouts and use them on other devices. Everything keeps working offline.")
                .font(.subheadline).foregroundStyle(Theme.textSecondary).textCase(nil)
        }
        #if DEBUG
        EmailSignInSection(busy: busy,
                           signIn: { email, password in run { try await env.sync.signIn(email: email, password: password) } },
                           signUp: { email, password in run { try await env.sync.signUp(email: email, password: password) } })
        #endif
    }

    /// Runs an account action with the form disabled; shows its user-facing message on failure.
    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do { try await action() } catch {
                AppEnvironment.log.error("Account action failed: \(String(describing: error), privacy: .public)")
                self.error = (error as? AuthFailure)?.message ?? "Something went wrong. Please try again."
            }
            busy = false
        }
    }
}
