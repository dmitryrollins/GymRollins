import GymData
import GymSync
import SwiftUI

/// Settings › AI agents (plan 32; the screen was "Claude" before), top to bottom: the agents connected to the
/// account, each with Disconnect; Connect (the MCP connector URL and Approve a connection); plan changes the agents
/// proposed; what agents may do (synced profile flags, one set for every agent, enforced by the server); the prompt to
/// use with Claude; and Disconnect all. The type and its `claude.*` identifiers keep their names, so the tests stay
/// put; elements new in plan 32 use `agents.*`.
struct ClaudeConnectionView: View {
    struct Permissions: Equatable {
        var readWorkouts = true
        var readBody = true
        var readPlan = true
        var readGyms = true
        var propose = true
        var autoApply = false
        var logWorkouts = false

        static let none = Permissions(readWorkouts: false, readBody: false, readPlan: false, readGyms: false,
                                      propose: false, autoApply: false, logWorkouts: false)
    }

    @Environment(AppEnvironment.self) private var env
    @State private var permissions = Permissions()
    @State private var loaded = false
    @State private var agents = AgentsModel()
    @State private var pending: [Proposal] = []
    @State private var recent: [Proposal] = []
    @State private var copied = false
    @State private var approving = false
    @State private var confirmDisconnect = false
    @State private var disconnected = false
    @State private var error: String?

    var body: some View {
        Form {
            ConnectedAgentsSection(model: agents, now: env.now()) { agent in
                Task { await agents.disconnect(agent, env.agentCalls) }
            }
            connectSection
            if !pending.isEmpty || !undoable.isEmpty { proposalsSection }
            permissionsSection
            UseWithClaudeSection()
            disconnectSection
            if let error {
                Section { Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("claude.error") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("AI agents")
        .task(id: env.planRevision) { reload() }
        .task { await loadAgents() }
        .refreshable { await loadAgents() }
        .onChange(of: permissions) { _, new in save(new) }
        .confirmationDialog("Disconnect every agent?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect all", role: .destructive) { Task { await disconnect() } }
                .accessibilityIdentifier("claude.disconnect.confirm")
        } message: {
            Text("Each one loses access until you approve it again, and everything agents can do is turned off.")
        }
        .sheet(isPresented: $approving, onDismiss: { Task { await loadAgents() } }) { approveSheet }
    }

    // MARK: Sections

    private var connectSection: some View {
        Section("Connect") {
            ConnectorInstructions(connectorURL: env.connectorURL, copied: $copied)
            Button("Approve a connection") { approving = true }
                .accessibilityIdentifier("claude.approveConnection")
        }
    }

    /// A fresh model each time the sheet opens, asking through the account's sync coordinator.
    private var approveSheet: some View {
        NavigationStack {
            ApproveConnectionView(model: ApproveConnectionModel(
                lookUp: { [sync = env.sync] code in try await sync.connectRequest(code: code) },
                decide: { [sync = env.sync] code, decision in
                    try await sync.decideConnect(code: code, decision: decision)
                }
            ))
        }
    }

    private var undoable: [Proposal] { recent.filter { $0.canUndo(at: env.now()) } }

    private var proposalsSection: some View {
        Section("Plan changes from your agents") {
            ForEach(pending) { p in
                NavigationLink { ProposalReviewView(proposalId: p.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.summary).lineLimit(2)
                        Text(AgentText.caption([p.createdAt.formatted(.dateTime.day().month(.abbreviated)),
                                                p.fromAgent.map(AgentText.from), "Review"]))
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .accessibilityIdentifier("claude.proposal.\(p.id.uuidString)")
            }
            ForEach(undoable) { p in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.summary).lineLimit(2)
                        Text(AgentText.caption([p.autoApplied ? "Applied automatically" : "Applied",
                                                p.fromAgent.map(AgentText.from)]))
                            .font(.caption).foregroundStyle(Theme.textSecondary)
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
            Toggle("Gyms", isOn: $permissions.readGyms).accessibilityIdentifier("claude.perm.readGyms")
            Toggle(isOn: $permissions.logWorkouts) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add workouts")
                    Text("Let agents add past workouts to your history")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
            .accessibilityIdentifier("agents.perm.logWorkouts")
            Toggle("Propose plan changes", isOn: $permissions.propose).accessibilityIdentifier("claude.perm.propose")
            Toggle("Apply changes without asking", isOn: $permissions.autoApply)
                .accessibilityIdentifier("claude.perm.autoApply")
        } header: {
            Text("What agents can do")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Agents can read gyms you've synced or shared. \"This phone only\" gyms stay on your phone, so "
                     + "agents can't see them.")
                    .accessibilityIdentifier("claude.gymsNote")
                Text("A workout an agent adds goes straight into your history, marked with the agent's name. You can "
                     + "edit or delete it like any other.")
                    .accessibilityIdentifier("agents.logWorkoutsNote")
                Text("With \u{201C}Apply changes without asking\u{201D} on, an agent's plan changes are applied the "
                     + "next time GymRollins opens, without a review. Applied changes can be undone for 7 days.")
                    .accessibilityIdentifier("agents.autoApplyNote")
            }
        }
        .tint(Theme.primaryFill)
    }

    private var disconnectSection: some View {
        Section {
            Button("Disconnect all", role: .destructive) { confirmDisconnect = true }
                .accessibilityIdentifier("claude.disconnect")
            if disconnected {
                Text("Every agent's access was revoked: none can read your data, propose changes or add workouts. "
                     + "To remove the connector from an agent too, remove GymRollins from its connectors (in Claude: "
                     + "Settings \u{2192} Connectors).")
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

    private func loadAgents() async {
        await agents.load(env.agentCalls)
    }

    private static func permissions(_ p: Profile) -> Permissions {
        Permissions(readWorkouts: p.mcpReadWorkouts, readBody: p.mcpReadBody, readPlan: p.mcpReadPlan,
                    readGyms: p.mcpReadGyms, propose: p.mcpPropose, autoApply: p.mcpAutoApply,
                    logWorkouts: p.mcpLogWorkouts)
    }

    private func save(_ new: Permissions) {
        guard loaded, new != Self.permissions(env.profile) else { return }
        do {
            try env.saveMcpPermissions(readWorkouts: new.readWorkouts, readBody: new.readBody, readPlan: new.readPlan,
                                       readGyms: new.readGyms, propose: new.propose, autoApply: new.autoApply,
                                       logWorkouts: new.logWorkouts)
            error = nil
        } catch {
            AppEnvironment.log.error("Save agent permissions failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save what agents can do. Please try again."
        }
    }

    /// Every flag off and pushed to the account, then every agent's grant revoked; "revoked" shows only when both
    /// worked. The list is asked again either way.
    private func disconnect() async {
        do {
            try await env.disconnectClaude()
            error = nil
            disconnected = true
            agents.removeAll()
        } catch {
            AppEnvironment.log.error("Disconnect all failed: \(error.localizedDescription, privacy: .public)")
            self.error = (error as? ClaudeDisconnectError ?? .permissionsNotSaved).message
            disconnected = false
        }
        permissions = Self.permissions(env.profile)
        await loadAgents()
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
