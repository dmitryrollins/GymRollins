import GymData
import SwiftUI

/// "Unblock everyone" in Settings, with a dialog like Delete Account's (a card at the foot of this long list would open
/// under the tab bar), then how many people it cleared.
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
        case .dailyLimit: "You've unblocked people a few times today. Try again tomorrow."
        default: "Couldn't unblock right now. Please try again."
        }
    }

    var body: some View {
        Button { confirming = true; outcome = nil } label: {
            Text("Unblock everyone").foregroundStyle(Theme.textPrimary)
        }
        .disabled(working)
        .accessibilityIdentifier("settings.unblockAll")
        .confirmationDialog("Unblock everyone?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Unblock", action: unblock).accessibilityIdentifier("settings.unblockAll.confirm")
        } message: {
            Text("What these users shared will show again at every gym.")
        }
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

    private func unblock() {
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
