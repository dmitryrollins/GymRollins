import SwiftUI

/// Swipe a view left to reveal a red Delete button at its trailing edge; a long swipe deletes straight away. For rows
/// that aren't in a `List` (which would give this for free). Only horizontal drags count, so the screen still scrolls.
///
/// The view doesn't slide: it narrows by the revealed width (a trailing padding), so whatever sits to its leading side
/// stays put. The button takes the height and vertical position of the view marked `swipeToDeleteTarget()` (the first
/// one, if several are), so labels or captions around that view never stretch or move it. Without a target it is as
/// tall as the whole view.
struct SwipeToDelete: ViewModifier {
    /// nil turns the gesture off (e.g. a logged set, or the last one).
    let onDelete: (() -> Void)?
    let identifier: String
    /// Any change closes an open Delete button (e.g. the screen scrolled, or a box took focus).
    let closing: Int

    /// How far the view has narrowed: the button plus the gap before it.
    @State private var reveal: CGFloat = 0
    @State private var dragStart: CGFloat?

    static let buttonWidth: CGFloat = 64
    /// Between the view and the button; matches the set boxes' spacing.
    static let gap: CGFloat = 12
    static let cornerRadius: CGFloat = 12
    /// A swipe this far deletes without the extra tap.
    static let fullSwipe: CGFloat = 200

    func body(content: Content) -> some View {
        content
            .padding(.trailing, reveal)
            .overlayPreferenceValue(SwipeToDeleteTargetKey.self) { anchor in
                GeometryReader { proxy in
                    if let onDelete, reveal > Self.gap {
                        let target = anchor.map { proxy[$0] } ?? CGRect(origin: .zero, size: proxy.size)
                        let width = reveal - Self.gap
                        deleteButton(onDelete)
                            .frame(width: width, height: target.height)
                            .position(x: proxy.size.width - width / 2, y: target.midY)
                    }
                }
            }
            // A modifier rather than an `if`, so a set turning removable (or not) keeps its boxes and their focus.
            .simultaneousGesture(drag, isEnabled: onDelete != nil)
            .onChange(of: onDelete == nil) { _, off in
                if off { reveal = 0 }
            }
            .onChange(of: closing) { reveal = 0 }
            .animation(.snappy(duration: 0.2), value: reveal)
    }

    private func deleteButton(_ onDelete: @escaping () -> Void) -> some View {
        Button(role: .destructive) { delete(onDelete) } label: {
            Image(systemName: "trash").font(.body.weight(.semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.primaryFill) // the Log Set red: white on it reads (Theme.destructive is too light)
                .clipShape(.rect(cornerRadius: Self.cornerRadius)) // also clips the icon while the button is still narrow
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete set")
        .accessibilityIdentifier(identifier)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let start = dragStart ?? reveal
                dragStart = start
                reveal = min(max(0, start - value.translation.width), Self.fullSwipe)
            }
            .onEnded { _ in
                dragStart = nil
                if reveal >= Self.fullSwipe, let onDelete {
                    delete(onDelete)
                } else {
                    let open = Self.buttonWidth + Self.gap
                    reveal = reveal > open / 2 ? open : 0
                }
            }
    }

    private func delete(_ onDelete: () -> Void) {
        reveal = 0
        onDelete()
    }
}

/// The bounds the revealed Delete button lines up with; the first marked view wins.
struct SwipeToDeleteTargetKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// `closing`: any change closes an open Delete button.
    func swipeToDelete(identifier: String, closing: Int = 0, onDelete: (() -> Void)?) -> some View {
        modifier(SwipeToDelete(onDelete: onDelete, identifier: identifier, closing: closing))
    }

    /// Marks the view whose height and vertical position the `swipeToDelete` button takes.
    func swipeToDeleteTarget() -> some View {
        anchorPreference(key: SwipeToDeleteTargetKey.self, value: .bounds) { $0 }
    }
}
