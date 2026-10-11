import Foundation
import GymWatchLink
import HealthKit
import os

/// `PhoneWatchTransport` over WatchConnectivity, plus HealthKit's `startWatchApp`, which launches the watch app (in the
/// background if needed) straight into its workout session when a workout starts on the phone.
@MainActor
final class WatchConnectivityTransport: PhoneWatchTransport {
    private let link = WatchConnectivityLink()
    private let healthStore: HKHealthStore? = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil
    private nonisolated static let log = Logger(subsystem: "com.rollins.gymrollins", category: "watch")

    var onCommand: ((WatchCommand) -> Void)? {
        get { link.onCommand }
        set { link.onCommand = newValue }
    }

    var onReady: (() -> Void)? {
        get { link.onActivated }
        set { link.onActivated = newValue }
    }

    func activate() { link.activate() }

    func push(_ state: WatchState) { link.send(state: state) }

    func launchWatchWorkout() {
        guard link.watchAppInstalled, let healthStore else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        healthStore.startWatchApp(with: configuration) { _, error in
            if let error {
                Self.log.notice("Starting the watch workout failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
