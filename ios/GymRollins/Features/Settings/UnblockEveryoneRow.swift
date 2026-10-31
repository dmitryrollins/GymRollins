import GymData
import SwiftUI

/// "Unblock everyone" in Settings, with an inline confirmation like `BlockAuthorCard`, then how many people it cleared.
struct UnblockEveryoneRow: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirming = false
    @State private var working = false
    @State private var outcome: Outcome?

    enum Outcome: Equatable {
        case done(Int)
        case failed(String)
    }

    static func resultText(count: Int) -> String {
        switch count {
        case 0: "No one was blocked."
        case 1: "Unblocked 1 person."
        default: "Unblocked \(count) people."
        }
    }

    static func errorText(_ error: Error) -> String {
        switch error as? GymCatalogError {
        case .offline: "Couldn't unblock. Check your connection and try again."
        case .signedOut: "Sign in to unblock people."
        default: "Couldn't unblock right now. Please try again."
        }
    }

    var body: some View {
        Button { confirming = true; outcome = nil } label: {
            Text("Unblock everyone").foregroundStyle(Theme.textPrimary)
        }
        .disabled(working)
        .accessibilityIdentifier("settings.unblockAll")
        if confirming { card }
        switch outcome {
        case .done(let count):
            Text(Self.resultText(count: count)).font(.footnote).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("settings.unblockAll.result")
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(Theme.destructive)
                .accessibilityIdentifier("settings.unblockAll.error")
        case nil:
            EmptyView()
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Unblock everyone?").font(.headline).foregroundStyle(Theme.textPrimary)
            Text("What these users shared will show again at every gym.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("settings.unblockAll.message")
            HStack(spacing: 10) {
                SecondaryGlassButton(title: "Cancel", identifier: "settings.unblockAll.cancel") { confirming = false }
                PrimaryGlassButton(title: "Unblock", identifier: "settings.unblockAll.confirm", action: unblock)
            }
        }
        .padding(12)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .contain)
    }

    private func unblock() {
        confirming = false
        working = true
        Task {
            do {
                outcome = .done(try await env.unblockAllAuthors())
            } catch {
                AppEnvironment.log.error("Unblock everyone failed: \(error.localizedDescription, privacy: .public)")
                outcome = .failed(Self.errorText(error))
            }
            working = false
        }
    }
}
