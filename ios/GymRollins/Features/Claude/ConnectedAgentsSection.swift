import GymSync
import SwiftUI

/// Settings › AI agents, first section (plan 32): one row per agent connected to the account, newest connection
/// first, each with Disconnect, which asks first. While there's no row, one line says why: checking, none connected,
/// or couldn't load (`claude.status`, where "Last used" was before plan 32).
struct ConnectedAgentsSection: View {
    let model: AgentsModel
    let now: Date
    let onDisconnect: (ConnectedAgent) -> Void

    var body: some View {
        Section {
            if let status = model.statusText {
                Text(status).foregroundStyle(Theme.textSecondary).accessibilityIdentifier("claude.status")
            }
            ForEach(model.agents) { agent in
                // One Disconnect at a time: every row waits while one is on its way (added after review).
                AgentRow(agent: agent, now: now, busy: model.disconnecting != nil) { onDisconnect(agent) }
            }
            if let error = model.error {
                Text(error).font(.footnote).foregroundStyle(Theme.destructive).accessibilityIdentifier("agents.error")
            }
        } header: {
            Text("Connected agents")
        } footer: {
            Text("Agents you approve can read your training and suggest plan changes you review here, within what "
                 + "agents can do below.")
                .accessibilityIdentifier("claude.view")
        }
    }
}

/// One agent: its name, the host its sign-in returns to, when it last used GymRollins, and Disconnect. Disconnect is
/// a borderless button of its own, so tapping the row's text does nothing (a Form row fires every button it holds).
private struct AgentRow: View {
    let agent: ConnectedAgent
    let now: Date
    let busy: Bool
    let onDisconnect: () -> Void
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(agent.name).font(.body.weight(.semibold)).lineLimit(2)
                .accessibilityIdentifier("agents.name.\(agent.clientId)")
            Text(agent.host).font(.footnote).foregroundStyle(Theme.textSecondary)
                .accessibilityLabel(AgentText.connectedFrom(agent.host))
                .accessibilityIdentifier("agents.host.\(agent.clientId)")
            Text(AgentText.lastUsed(agent.lastUsedAt, now: now)).font(.footnote).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("agents.lastUsed.\(agent.clientId)")
            Button("Disconnect", role: .destructive) { confirming = true }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                .disabled(busy)
                .accessibilityLabel(AgentText.disconnectLabel(agent.name))
                .accessibilityIdentifier("agents.disconnect.\(agent.clientId)")
        }
        .confirmationDialog(AgentText.confirmDisconnect(agent.name), isPresented: $confirming,
                            titleVisibility: .visible) {
            Button("Disconnect", role: .destructive, action: onDisconnect)
                .accessibilityIdentifier("agents.disconnect.confirm")
        }
    }
}
