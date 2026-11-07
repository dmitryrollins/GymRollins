import GymCore
import SwiftUI
import UIKit

/// "Use with Claude" and "Ready requests" on the Claude screen, under Connect: the coach prompt to paste into a Claude
/// Project's instructions, and requests to paste into a chat in that project. One control per row, like Connect's URL
/// and Copy URL rows, because a Form row fires every button it holds. `unit` is the profile's current unit, passed on
/// every draw, so a switch in Settings shows here without anything stored.
struct UseWithClaudeSection: View {
    let unit: WeightUnit
    @State private var model = UseWithClaudeModel()
    @State private var showAll = false

    var body: some View {
        Section {
            Text(ClaudePrompts.coach)
                .font(.footnote)
                .lineLimit(showAll ? nil : 3)
                .accessibilityIdentifier("claude.coach.text")
            Button(showAll ? "Show less" : "Show all") { showAll.toggle() }
                .accessibilityIdentifier("claude.coach.showAll")
            Button(model.isCopied(UseWithClaudeModel.coachId) ? "Copied" : "Copy coach prompt") {
                copy(UseWithClaudeModel.coachId, ClaudePrompts.coach)
            }
            .accessibilityIdentifier("claude.coach.copy")
        } header: {
            Text("Use with Claude")
        } footer: {
            Text("In Claude, create a Project and paste this into its instructions. Chat in that project.")
        }
        Section {
            ForEach(ClaudePrompts.requests(unit: unit)) { request in
                Button { copy(request.id, request.text) } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(request.text).foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 12)
                        Text(model.isCopied(request.id) ? "Copied" : "Copy")
                    }
                }
                .accessibilityLabel(request.text)
                .accessibilityValue(model.isCopied(request.id) ? "Copied" : "")
                .accessibilityHint("Copies the request")
                .accessibilityIdentifier("claude.request.\(request.id)")
            }
        } header: {
            Text("Ready requests")
        } footer: {
            Text("Paste one into a chat in your Claude Project.")
        }
    }

    private func copy(_ id: String, _ text: String) {
        model.copy(id, text: text) { UIPasteboard.general.string = $0 }
    }
}
