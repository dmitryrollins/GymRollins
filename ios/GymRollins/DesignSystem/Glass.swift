import SwiftUI

extension View {
    /// Glass capsule for chips, pills and floating bars.
    func glassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: .capsule)
            .modifier(InteractiveGlass(enabled: interactive))
    }

    /// Glass circle for icon buttons (44 pt). The button style sizes the *label* to 44 pt too: a frame applied
    /// only outside a `Button` leaves its accessibility/hit region at the glyph's size (audit: hit area too small).
    func glassCircle() -> some View {
        buttonStyle(HitAreaButtonStyle(horizontalPadding: 0))
            .frame(width: Theme.minTapSize, height: Theme.minTapSize)
            .glassEffect(.regular.interactive(), in: .circle)
    }
}

private struct InteractiveGlass: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View { content } // `.interactive()` is applied via the Glass value when needed
}

/// Plain button style whose label is padded to at least 44 × 44 pt with a full-rect content shape, so the button's
/// hit and accessibility region is the whole chip/circle rather than just its text or glyph.
struct HitAreaButtonStyle: ButtonStyle {
    var horizontalPadding: CGFloat = 14
    var minHeight: CGFloat = Theme.minTapSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: Theme.minTapSize, minHeight: minHeight)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Full-width primary action (one per screen).
struct PrimaryGlassButton: View {
    let title: String
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.primaryFill)
        .accessibilityIdentifier(identifier ?? title)
    }
}

/// Secondary glass pill button (content-hugging — for chips and compact controls).
struct GlassPillButton: View {
    let title: String
    var systemImage: String? = nil
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier(identifier ?? title)
    }
}

/// Full-width secondary action (e.g. onboarding's "Skip"/"Later" below a `PrimaryGlassButton`). The `maxWidth`
/// must be on the label *inside* the button (matching `PrimaryGlassButton`): applying `.frame` after
/// `.buttonStyle(.glass)` only widens the tap target, not the visible glass capsule, leaving a small
/// content-hugging pill instead of a full-width bar.
struct SecondaryGlassButton: View {
    let title: String
    var identifier: String? = nil
    var minHeight: CGFloat = Theme.minTapSize
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: minHeight)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier(identifier ?? title)
    }
}
