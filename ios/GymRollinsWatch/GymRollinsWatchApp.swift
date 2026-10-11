import HealthKit
import SwiftUI
import WatchKit

/// GymRollins on Apple Watch (plan 17): a companion to the iPhone app, which owns the workout. watchOS 10 (Series 5).
@main
struct GymRollinsWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(delegate.model)
        }
        .onChange(of: scenePhase) { _, phase in
            delegate.model.isActive = phase == .active
        }
    }
}

/// Receives the phone's "start the watch workout" launch and HealthKit's session recovery.
@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    let model = WatchAppModel()

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        model.startedFromPhone()
    }

    func handleActiveWorkoutRecovery() {
        model.recoverWorkout()
    }
}
