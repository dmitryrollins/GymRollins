import SwiftUI

/// The bar above the keyboard while a set's box is edited, styled like the system's form bar (Safari): previous and
/// next box in one glass capsule on the left, a plain "Done" capsule on the right, white rather than the app's red.
/// The screen draws it in its bottom inset instead of a `.keyboard` toolbar, so nothing is painted behind the capsules
/// and they sit `gap` above the keys instead of touching them.
struct KeyboardBar: View {
    let canMovePrevious: Bool
    let canMoveNext: Bool
    let movePrevious: () -> Void
    let moveNext: () -> Void
    let done: () -> Void

    /// Space between the capsules and the top of the keyboard.
    static let gap: CGFloat = 6

    var body: some View {
        HStack {
            HStack(spacing: 0) {
                arrow("Previous field", systemImage: "chevron.up", enabled: canMovePrevious, action: movePrevious)
                    .accessibilityIdentifier("keyboard.previous")
                arrow("Next field", systemImage: "chevron.down", enabled: canMoveNext, action: moveNext)
                    .accessibilityIdentifier("keyboard.next")
            }
            .padding(.horizontal, 6)
            .glassEffect(.regular.interactive(), in: .capsule)
            Spacer()
            Button("Done", action: done)
                .font(.body)
                .buttonStyle(HitAreaButtonStyle(horizontalPadding: 18))
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityIdentifier("keyboard.done")
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 16)
        .padding(.bottom, Self.gap)
    }

    private func arrow(_ title: String, systemImage: String, enabled: Bool,
                       action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.system(size: 19, weight: .medium))
            .buttonStyle(HitAreaButtonStyle(horizontalPadding: 6))
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
    }
}
