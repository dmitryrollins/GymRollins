#if DEBUG
import Foundation
import Observation
import SwiftUI

/// DEBUG/UI-test only (`-uiTesting`): an in-memory `WorkoutActivityClient`, so UI tests never depend on the
/// simulator's ActivityKit, plus a probe (`-liveActivityProbe`) that shows what the lock screen would show.
@MainActor
@Observable
final class RecordingActivityClient: WorkoutActivityClient {
    static let shared = RecordingActivityClient()

    private(set) var state: WorkoutActivityAttributes.ContentState?
    private(set) var starts = 0
    private var activityId: String?

    func running() -> [RunningWorkoutActivity] { [] }

    func start(_ attributes: WorkoutActivityAttributes, state: WorkoutActivityAttributes.ContentState) throws -> String {
        starts += 1
        self.state = state
        let id = "recorded-\(starts)"
        activityId = id
        return id
    }

    func update(id: String, state: WorkoutActivityAttributes.ContentState) async {
        guard id == activityId else { return }
        self.state = state
    }

    func end(id: String) async {
        guard id == activityId else { return }
        state = nil
        activityId = nil
    }

    /// "Set 2/3 · 135 lb × 8 · rest · log · starts 1", or "none · starts 1".
    var summary: String {
        guard let state else { return "none · starts \(starts)" }
        return [state.setLabel, state.setDetail, state.restEndsAt == nil ? "no rest" : "rest",
                state.canLogSet ? "log" : "no log", "starts \(starts)"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The probe text (`liveActivity.probe`), only under `-liveActivityProbe`.
struct LiveActivityProbe: View {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-liveActivityProbe")
    private let recorder = RecordingActivityClient.shared

    var body: some View {
        Text(recorder.summary)
            .font(.caption2)
            .foregroundStyle(.white)
            .background(.black)
            .allowsHitTesting(false)
            .accessibilityIdentifier("liveActivity.probe")
    }
}
#endif
