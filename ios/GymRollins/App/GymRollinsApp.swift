import GymWatchLink
import SwiftUI

@main
struct GymRollinsApp: App {
    @State private var boot = Boot()

    var body: some Scene {
        WindowGroup {
            switch boot.state {
            case .ready(let env):
                RootView().environment(env)
            case .failed(let message):
                ContentUnavailableView("Can't open your data", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            }
        }
    }
}

@MainActor
@Observable
final class Boot {
    enum State { case ready(AppEnvironment), failed(String) }
    let state: State
    /// Keeps the workout Live Activity in step with the environment; nil when boot failed.
    private let liveActivity: LiveActivityController?
    /// Keeps the Apple Watch app in step and applies its commands (plan 17); nil when boot failed.
    private let watch: WatchSyncController?

    init() {
        do {
            let env = try AppEnvironment()
            state = .ready(env)
            liveActivity = Self.startLiveActivity(env: env)
            watch = Self.startWatch(env: env)
        } catch {
            liveActivity = nil
            watch = nil
            AppEnvironment.log.fault("Boot failed: \(error.localizedDescription, privacy: .public)")
            state = .failed("Your data wasn't changed. Force-quit and reopen GymRollins. If it keeps happening, "
                + "restart your iPhone and contact support.")
        }
    }

    /// Starts observing the environment for the workout Live Activity and routes its buttons (`LiveActivityIntent`s,
    /// run in this process) to the in-progress session, refreshing the activity before the intent returns.
    private static func startLiveActivity(env: AppEnvironment) -> LiveActivityController {
        let controller = LiveActivityController(client: activityClient())
        controller.observe { [weak env] in env?.liveActivitySnapshot }
        WorkoutActivityIntentRouter.handler = { [weak env, weak controller] action in
            env?.performActivityAction(action)
            await controller?.refresh()
        }
        return controller
    }

    /// Starts the WatchConnectivity link: the watch gets the workout as it changes, and its commands go through the
    /// same session operations as the Live Activity's buttons.
    private static func startWatch(env: AppEnvironment) -> WatchSyncController {
        let handler = WatchCommandHandler(defaults: env.defaults, hooks: env.watchCommandHooks)
        let controller = WatchSyncController(transport: watchTransport(), defaults: env.defaults, now: env.now,
                                             handler: handler,
                                             resolveEnded: { [weak env] id in
                                                 env?.endedWatchWorkout(id)
                                                     ?? WatchEndedWorkout(workoutId: id, endedAt: Date(), finished: false,
                                                                          watchRecordsHealth: false)
                                             })
        controller.observe { [weak env] in
            env?.watchSnapshot ?? WatchSyncController.Snapshot(workout: nil, today: nil, healthEnabled: false)
        }
        return controller
    }

    private static func watchTransport() -> PhoneWatchTransport {
        #if DEBUG
        if FakeWatchTransport.isEnabled { return FakeWatchTransport.shared }
        #endif
        return WatchConnectivityTransport()
    }

    private static func activityClient() -> WorkoutActivityClient {
        #if DEBUG
        if LaunchOptions().uiTesting { return RecordingActivityClient.shared }
        #endif
        return ActivityKitClient()
    }
}
