import GymData
import SwiftUI

/// Connecting Claude: the MCP connector URL and how to add it, when Claude last used it, what Claude may do
/// (synced profile flags; the server enforces the read/propose ones), pending and recent proposals, and
/// "Disconnect". Reached from Account until plan 07's Settings.
struct ClaudeConnectionView: View {
    struct Permissions: Equatable {
        var readWorkouts = true
        var readBody = true
        var readPlan = true
        var propose = true
        var autoApply = false

        static let none = Permissions(readWorkouts: false, readBody: false, readPlan: false, propose: false,
                                      autoApply: false)
    }

    @Environment(AppEnvironment.self) private var env
    @State private var permissions = Permissions()
    @State private var loaded = false
    @State private var lastUse: Date?
    @State private var checkedLastUse = false
    @State private var pending: [Proposal] = []
    @State private var recent: [Proposal] = []
    @State private var copied = false
    @State private var confirmDisconnect = false
    @State private var disconnected = false
    @State private var error: String?

    var body: some View {
        Form {
            statusSection
            connectSection
            if !pending.isEmpty || !undoable.isEmpty { proposalsSection }
            permissionsSection
            disconnectSection
            if let error {
                Section { Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("claude.error") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Claude")
        .task(id: env.planRevision) { reload() }
        .task { await loadLastUse() }
        .onChange(of: permissions) { _, new in save(new) }
        .confirmationDialog("Turn off everything Claude can do?", isPresented: $confirmDisconnect,
                            titleVisibility: .visible) {
            Button("Disconnect Claude", role: .destructive) { Task { await disconnect() } }
                .accessibilityIdentifier("claude.disconnect.confirm")
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                Text(statusText).foregroundStyle(Theme.textSecondary).accessibilityIdentifier("claude.status")
            }
        } header: {
            Text("Ask Claude about your training and let it suggest plan changes you review here.")
                .font(.subheadline).foregroundStyle(Theme.textSecondary).textCase(nil)
                .accessibilityIdentifier("claude.view")
        }
    }

    private var statusText: String {
        guard let lastUse else { return checkedLastUse ? "Not connected yet" : "Checking\u{2026}" }
        return "Last used " + lastUse.formatted(.dateTime.day().month(.abbreviated))
    }

    private var connectSection: some View {
        Section("Connect") { ConnectorInstructions(connectorURL: env.connectorURL, copied: $copied) }
    }

    private var undoable: [Proposal] { recent.filter { $0.canUndo(at: env.now()) } }

    private var proposalsSection: some View {
        Section("Plan changes from Claude") {
            ForEach(pending) { p in
                NavigationLink { ProposalReviewView(proposalId: p.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.summary).lineLimit(2)
                        Text(p.createdAt.formatted(.dateTime.day().month(.abbreviated)) + " \u{00B7} Review")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .accessibilityIdentifier("claude.proposal.\(p.id.uuidString)")
            }
            ForEach(undoable) { p in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.summary).lineLimit(2)
                        Text(p.autoApplied ? "Applied automatically" : "Applied").font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Undo") { undo(p.id) }.buttonStyle(.glass)
                        .accessibilityIdentifier("claude.undo.\(p.id.uuidString)")
                }
            }
        }
    }

    private var permissionsSection: some View {
        Section {
            Toggle("Read workouts and sets", isOn: $permissions.readWorkouts)
                .accessibilityIdentifier("claude.perm.readWorkouts")
            Toggle("Read bodyweight", isOn: $permissions.readBody).accessibilityIdentifier("claude.perm.readBody")
            Toggle("Read your plan and profile", isOn: $permissions.readPlan)
                .accessibilityIdentifier("claude.perm.readPlan")
            Toggle("Propose plan changes", isOn: $permissions.propose).accessibilityIdentifier("claude.perm.propose")
            Toggle("Apply changes without asking", isOn: $permissions.autoApply)
                .accessibilityIdentifier("claude.perm.autoApply")
        } header: {
            Text("What Claude can do")
        } footer: {
            Text("Applied changes can be undone for 7 days.")
        }
        .tint(Theme.primaryFill)
    }

    private var disconnectSection: some View {
        Section {
            Button("Disconnect Claude", role: .destructive) { confirmDisconnect = true }
                .accessibilityIdentifier("claude.disconnect")
            if disconnected {
                Text("Claude's access was revoked: it can no longer read your data or propose changes. To remove "
                     + "the connector too, open Claude \u{2192} Settings \u{2192} Connectors and remove GymRollins.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("claude.disconnected")
            }
        }
    }

    // MARK: Actions

    private func reload() {
        let fromProfile = Self.permissions(env.profile)
        if !loaded || fromProfile != permissions {
            permissions = fromProfile
            loaded = true
        }
        pending = env.pendingProposals()
        do { recent = try env.proposals.recent(limit: 10) } catch {
            AppEnvironment.log.error("Load recent proposals failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadLastUse() async {
        lastUse = await env.sync.lastMcpUse()
        checkedLastUse = true
    }

    private static func permissions(_ p: Profile) -> Permissions {
        Permissions(readWorkouts: p.mcpReadWorkouts, readBody: p.mcpReadBody, readPlan: p.mcpReadPlan,
                    propose: p.mcpPropose, autoApply: p.mcpAutoApply)
    }

    private func save(_ new: Permissions) {
        guard loaded, new != Self.permissions(env.profile) else { return }
        do {
            try env.saveMcpPermissions(readWorkouts: new.readWorkouts, readBody: new.readBody, readPlan: new.readPlan,
                                       propose: new.propose, autoApply: new.autoApply)
            error = nil
        } catch {
            AppEnvironment.log.error("Save Claude permissions failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save Claude's permissions. Please try again."
        }
    }

    /// Flags off and pushed to the account, then the OAuth grant is revoked; "revoked" shows only when both worked.
    private func disconnect() async {
        do {
            try await env.disconnectClaude()
            error = nil
            disconnected = true
        } catch {
            AppEnvironment.log.error("Disconnect Claude failed: \(error.localizedDescription, privacy: .public)")
            self.error = (error as? ClaudeDisconnectError ?? .permissionsNotSaved).message
            disconnected = false
        }
        permissions = Self.permissions(env.profile)
    }

    private func undo(_ id: UUID) {
        do {
            if try !env.undoProposal(id) { error = "This change can no longer be undone." }
        } catch {
            AppEnvironment.log.error("Undo proposal failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't undo. Your plan wasn't changed."
        }
    }
}
