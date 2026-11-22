import SwiftUI

/// The glass top bar of a screen in Fitness' layout (the workout and outside-workout details): Back on the left, the
/// screen's own controls on the right. `detailTopBar(_:)` pins it above the scrolling content, where iOS 26's scroll-edge
/// effect hides what passes under it, instead of the content sliding under the status bar.
struct DetailTopBar<Trailing: View>: View {
    /// The Back circle's accessibility identifier (`detail.back`, `outside.back`).
    let backIdentifier: String
    let onBack: () -> Void
    @ViewBuilder let trailing: Trailing

    /// The bar's space above the content: its top padding and the 44 pt circles. A backdrop that sat behind the
    /// scrolling bar is moved up by this much to stay where it was.
    static var height: CGFloat { topPadding + Theme.minTapSize }

    private static var topPadding: CGFloat { 8 }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .glassCircle()
                .accessibilityLabel("Back")
                .accessibilityIdentifier(backIdentifier)
            Spacer()
            trailing
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, Self.topPadding)
    }
}

extension DetailTopBar where Trailing == EmptyView {
    init(backIdentifier: String, onBack: @escaping () -> Void) {
        self.init(backIdentifier: backIdentifier, onBack: onBack, trailing: { EmptyView() })
    }
}

extension View {
    /// Pins `bar` above this scroll view (`safeAreaBar`) with the hard scroll-edge effect: what scrolls under the bar
    /// and the status bar is hidden. The soft one only faded it, so text showed through behind the clock and the
    /// circles.
    func detailTopBar<Trailing: View>(_ bar: DetailTopBar<Trailing>) -> some View {
        safeAreaBar(edge: .top, spacing: 0) { bar }
            .scrollEdgeEffectStyle(.hard, for: .top)
    }
}
