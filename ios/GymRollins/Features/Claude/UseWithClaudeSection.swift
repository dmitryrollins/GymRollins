import SwiftUI
import UIKit

/// "Use with Claude" on the Claude screen: the one prompt to paste into a Claude Project's instructions. After that the
/// owner just talks to Claude, which asks for whatever it needs. One control per row, like Connect's URL and Copy URL
/// rows, because a Form row fires every button it holds.
struct UseWithClaudeSection: View {
    @State private var showAll = false
    @State private var copied = false

    var body: some View {
        Section {
            Text(ClaudePrompts.coach)
                .font(.footnote)
                .lineLimit(showAll ? nil : 3)
                .accessibilityIdentifier("claude.coach.text")
            Button(showAll ? "Show less" : "Show all") { showAll.toggle() }
                .accessibilityIdentifier("claude.coach.showAll")
            Button(copied ? "Copied" : "Copy prompt") {
                UIPasteboard.general.string = ClaudePrompts.coach
                copied = true
            }
            .accessibilityIdentifier("claude.coach.copy")
        } header: {
            Text("Use with Claude")
        } footer: {
            Text("In Claude, create a Project and paste this into its instructions. Then chat in that project: ask for "
                 + "a workout, or anything about your training.")
        }
    }
}
