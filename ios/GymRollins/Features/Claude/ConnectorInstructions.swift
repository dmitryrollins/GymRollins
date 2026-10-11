import SwiftUI
import UIKit

/// The connector URL, its "copy" button, and the 3 setup steps, shared by `ClaudeConnectionView` (Settings) and
/// `ConnectClaudeStepView` (onboarding). Identifiers `claude.url` / `claude.copyURL` are stable across both hosts.
struct ConnectorInstructions: View {
    let connectorURL: String?
    @Binding var copied: Bool

    var body: some View {
        if let url = connectorURL {
            Text(url).font(.footnote.monospaced()).textSelection(.enabled).accessibilityIdentifier("claude.url")
            Button(copied ? "Copied" : "Copy URL") {
                UIPasteboard.general.string = url
                copied = true
            }
            .accessibilityIdentifier("claude.copyURL")
        } else {
            Text("This build isn't connected to a server.").foregroundStyle(Theme.textSecondary)
        }
        step(1, "Copy the connector URL")
        step(2, "In Claude: Settings \u{2192} Connectors \u{2192} Add custom connector, then paste it")
        step(3, "Approve access when asked")
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.footnote.weight(.bold)).foregroundStyle(Theme.accent)
            Text(text).font(.subheadline)
        }
    }
}
