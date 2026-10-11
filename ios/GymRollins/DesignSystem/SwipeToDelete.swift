import SwiftUI

/// Swipe a row left to reveal a red Delete button behind it; a long swipe deletes straight away. For rows that
/// aren't in a `List` (which would give this for free). Only horizontal drags count, so the screen still scrolls.
struct SwipeToDelete: ViewModifier {
    /// nil turns the gesture off (e.g. a logged set, or the last one).
    let onDelete: (() -> Void)?
    let identifier: String

    @State private var offset: CGFloat = 0
    @State private var dragStart: CGFloat?

    static let buttonWidth: CGFloat = 84
    /// A swipe this far deletes without the extra tap.
    static let fullSwipe: CGFloat = 200

    func body(content: Content) -> some View {
        if let onDelete {
            ZStack(alignment: .trailing) {
                if offset < 0 {
                    Button(role: .destructive) { delete(onDelete) } label: {
                        Image(systemName: "trash").font(.body.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: max(Self.buttonWidth, -offset), alignment: .center)
                            .frame(maxHeight: .infinity)
                            .background(Theme.primaryFill, in: .rect(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete set")
                    .accessibilityIdentifier(identifier)
                }
                content
                    .offset(x: offset)
                    .simultaneousGesture(drag(onDelete))
            }
            .animation(.snappy(duration: 0.2), value: offset)
        } else {
            content
        }
    }

    private func drag(_ onDelete: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let start = dragStart ?? offset
                dragStart = start
                offset = min(0, start + value.translation.width)
            }
            .onEnded { _ in
                dragStart = nil
                if offset <= -Self.fullSwipe {
                    delete(onDelete)
                } else {
                    offset = offset < -Self.buttonWidth / 2 ? -Self.buttonWidth : 0
                }
            }
    }

    private func delete(_ onDelete: () -> Void) {
        offset = 0
        onDelete()
    }
}

extension View {
    func swipeToDelete(identifier: String, onDelete: (() -> Void)?) -> some View {
        modifier(SwipeToDelete(onDelete: onDelete, identifier: identifier))
    }
}
