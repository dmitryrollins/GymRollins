import SwiftUI

/// Today's one-time ask (plan 39), for people who turned Apple Health on before the app read activity. Allow asks
/// Health for the new types and reads them. Not now hides the card for good, and Settings › Apple Health still asks.
struct ActivityPermissionCard: View {
    let asking: Bool
    let allow: () -> Void
    let notNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Bring in your Apple Watch activity", systemImage: "applewatch")
                .font(.headline).foregroundStyle(Theme.textPrimary)
            Text("Walks, runs and classes from your Apple Watch and other apps show in the Log and count toward your "
                 + "streak. Your steps and Activity rings show here.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecondaryGlassButton(title: "Not now", identifier: "today.activityCard.notNow", action: notNow)
                SecondaryGlassButton(title: asking ? "Asking\u{2026}" : "Allow", identifier: "today.activityCard.allow",
                                     action: allow)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.activityCard")
    }
}
