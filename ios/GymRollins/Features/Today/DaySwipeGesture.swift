import SwiftUI
import UIKit

/// A sideways swipe on Today's scroll view: left asks for the next day, right for the one before. The pan begins only
/// when the finger moves mostly sideways, so vertical scrolling is untouched, and once it begins the rows' own taps are
/// cancelled, so a swipe that starts on a row moves the day without opening the row.
struct DaySwipeGesture: UIGestureRecognizerRepresentable {
    /// Distance the finger must travel before the swipe counts.
    private static let minimumDistance: CGFloat = 80
    /// +1 for a swipe left (the next day), -1 for a swipe right (the previous one).
    let onSwipe: (Int) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard recognizer.state == .ended else { return }
        let dx = recognizer.translation(in: recognizer.view).x
        guard abs(dx) > Self.minimumDistance else { return }
        onSwipe(dx < 0 ? 1 : -1)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 2
        }
    }
}
