import SwiftUI
import WidgetKit

/// The widget extension: only the in-progress workout's Live Activity.
@main
struct GymRollinsWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivity()
    }
}
