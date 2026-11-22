import SwiftUI

/// The tabs' header in a contacts-app style (2026-11-18/19): Settings ("R") on the left, a wide glass
/// pill, and the screen's own buttons sharing one pill on the right. It stays at the top over a
/// blur of what scrolls under it.
extension View {
    /// Pins `header` above this scroll view or list. What scrolls under it is blurred, once the screen has scrolled.
    func fixedHeader<Header: View>(@ViewBuilder _ header: () -> Header) -> some View {
        modifier(FixedHeaderModifier(header: header()))
    }
}

private struct FixedHeaderModifier<Header: View>: ViewModifier {
    let header: Header
    /// Scrolled: the backdrop shows. At the top nothing is under the header, so there's none.
    @State private var scrolled = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 1 } action: { _, now in
                withAnimation(.easeOut(duration: 0.2)) { scrolled = now }
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                header
                    .padding(.horizontal, Theme.gutter)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
                    .background { HeaderBackdrop().opacity(scrolled ? 1 : 0) }
            }
            // iOS's own soft edge left the text under the header readable behind the clock.
            .scrollEdgeEffectHidden(true, for: .top)
    }
}

/// What scrolls under a fixed header: blurred up through the status bar, fading out just below the header. The blur
/// keeps the screen's black (owner, 2026-11-19): the material alone made a grey band.
private struct HeaderBackdrop: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Theme.background.opacity(0.6))
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Settings: the "R" circle at the left of every tab's header.
struct SettingsCircle: View {
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text("R").font(.headline) }
            .glassCircle()
            .accessibilityLabel("Settings")
            .accessibilityIdentifier(identifier)
    }
}

/// The header's right pill: its buttons side by side in one glass capsule, like the reference's compose and search.
struct HeaderButtons<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// A button's icon in `HeaderButtons`: white like the reference, grey while the button is off.
struct HeaderIcon: View {
    let systemName: String
    var dimmed = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Image(systemName: systemName)
            .font(.title3)
            .foregroundStyle(dimmed ? Theme.textSecondary : Theme.textPrimary)
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 4 : 0) // there the glyph outgrows 44 pt
            .frame(minWidth: Theme.minTapSize, minHeight: Theme.minTapSize)
            .contentShape(.rect)
    }
}

/// The header's wide pill for a screen: its name, and under it a short fact when it has one ("1,324 exercises"), like
/// a contacts list's "Contacts / 1,200 contacts".
struct HeaderPill: View {
    let title: String
    var subtitle: String? = nil
    /// The screen's accessibility prefix: "library" gives `library.title` and `library.subtitle`.
    let prefix: String

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("\(prefix).title")
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("\(prefix).subtitle")
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: Theme.minTapSize)
        .glassEffect(.regular, in: .capsule)
    }
}

/// A tab's header (Log, Body): Settings, the screen's name in the wide pill, and the screen's buttons, if it has any
/// (owner, 2026-11-19: the name only; each screen keeps its own controls under it). Library builds its own from the
/// same parts, for its search.
struct TabHeader<Actions: View>: View {
    let title: String
    /// The screen's accessibility prefix: "log" gives `log.settings` and `log.title`.
    let prefix: String
    let onSettings: () -> Void
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            SettingsCircle(identifier: "\(prefix).settings", action: onSettings)
            HeaderPill(title: title, prefix: prefix)
            if Actions.self != EmptyView.self { HeaderButtons { actions } }
        }
    }
}

extension TabHeader where Actions == EmptyView {
    init(title: String, prefix: String, onSettings: @escaping () -> Void) {
        self.init(title: title, prefix: prefix, onSettings: onSettings) { EmptyView() }
    }
}

/// A search field in the header's glass: Library's, in place of its pill while searching (owner, 2026-11-19: search
/// as in a contacts app, behind a button in the header). VoiceOver and UI tests find a search field.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    let identifier: String
    /// Takes the keyboard when it appears: it was opened to type in.
    var focusOnAppear = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .accessibilityAddTraits(.isSearchField)
                .accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .frame(minWidth: Theme.minTapSize, minHeight: Theme.minTapSize)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, text.isEmpty ? 14 : 0)
        .frame(maxWidth: .infinity, minHeight: Theme.minTapSize)
        .glassEffect(.regular, in: .capsule)
        .task { if focusOnAppear { focused = true } }
    }
}
