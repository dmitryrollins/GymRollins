import SwiftUI

/// The inline confirmation before hiding everything from one user, as in the picker: a system dialog didn't confirm
/// reliably under UI tests.
struct BlockAuthorCard: View {
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hide everything from this user?").font(.headline).foregroundStyle(Theme.textPrimary)
            Text("You won't see anything else they've shared at any gym. You can undo this in Settings.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("listing.block.message")
            HStack(spacing: 10) {
                SecondaryGlassButton(title: "Cancel", identifier: "listing.block.cancel", action: onCancel)
                PrimaryGlassButton(title: "Hide", identifier: "listing.block.confirm", action: onConfirm)
            }
        }
        .padding(12)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .contain)
    }
}
