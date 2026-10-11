import Foundation
import GymWatchLink
import os

/// The phone's side of the WatchConnectivity link (a fake under `-fakeWatch`).
@MainActor
protocol PhoneWatchTransport: AnyObject {
    var onCommand: ((WatchCommand) -> Void)? { get set }
    /// The link came up (anything pushed before was dropped).
    var onReady: (() -> Void)? { get set }
    func activate()
    func push(_ state: WatchState)
    /// Wakes the watch app into its workout session for a workout that just started (no-op without a watch app).
    func launchWatchWorkout()
}

/// Keeps the Apple Watch in step with the phone (plan 17): pushes the state whenever what it shows changes, remembers
/// how the last workout ended (so a watch that missed the moment still learns it — it decides whether the watch saves
/// the Health workout), wakes the watch's workout session when a workout starts, and hands watch commands to the
/// handler.
@MainActor
final class WatchSyncController {
    /// What the environment says right now (the controller adds the send time and the last ended workout).
    struct Snapshot: Equatable {
        var workout: WatchWorkout?
        var today: WatchToday?
        var healthEnabled: Bool
    }

    static let lastEndedKey = "watchLastEndedWorkout"
    static let runningKey = "watchRunningWorkout"
    private static let log = Logger(subsystem: "com.rollins.gymrollins", category: "watch")

    private let transport: PhoneWatchTransport
    private let defaults: UserDefaults
    private let now: () -> Date
    private let resolveEnded: @MainActor (UUID) -> WatchEndedWorkout
    private let handler: WatchCommandHandler
    private var source: (@MainActor () -> Snapshot)?
    private var lastSent: WatchState?
    private(set) var lastEnded: WatchEndedWorkout?
    /// The workout the watch was last told is running (persisted: a relaunch after the workout ended still reports it).
    private var running: UUID?

    init(transport: PhoneWatchTransport, defaults: UserDefaults, now: @escaping () -> Date = Date.init,
         handler: WatchCommandHandler, resolveEnded: @escaping @MainActor (UUID) -> WatchEndedWorkout) {
        self.transport = transport
        self.defaults = defaults
        self.now = now
        self.handler = handler
        self.resolveEnded = resolveEnded
        lastEnded = defaults.data(forKey: Self.lastEndedKey)
            .flatMap { try? JSONDecoder().decode(WatchEndedWorkout.self, from: $0) }
        running = defaults.string(forKey: Self.runningKey).flatMap(UUID.init(uuidString:))
        transport.onCommand = { [weak self] command in self?.receive(command) }
        transport.onReady = { [weak self] in self?.refresh() }
    }

    /// Starts the link and pushes `source()` now and whenever anything it read (Observation) changes.
    func observe(_ source: @escaping @MainActor () -> Snapshot) {
        self.source = source
        transport.activate()
        track()
    }

    /// Applies a snapshot: records a workout that ended, wakes the watch for a new one, pushes changed content.
    func apply(_ snapshot: Snapshot, force: Bool = false) {
        let current = snapshot.workout?.id
        if let previous = running, previous != current {
            setLastEnded(resolveEnded(previous))
        }
        if let current, current != running {
            transport.launchWatchWorkout()
        }
        setRunning(current)
        let state = WatchState(sentAt: now(), workout: snapshot.workout, lastEnded: lastEnded, today: snapshot.today,
                               healthEnabled: snapshot.healthEnabled)
        guard force || !(lastSent?.hasSameContent(as: state) ?? false) else { return }
        lastSent = state
        transport.push(state)
    }

    /// Pushes the current state even if unchanged.
    func refresh() {
        if let source { apply(source(), force: true) }
    }

    func receive(_ command: WatchCommand) {
        switch handler.handle(command) {
        case .applied:
            break // the change pushes by itself (observation)
        case .stateRequested, .ignored, .duplicate:
            // A stale or repeated action gets the current state back, so the watch stops showing what it acted on.
            refresh()
        }
    }

    // MARK: Private

    private func track() {
        guard let source else { return }
        let snapshot = withObservationTracking { source() } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        apply(snapshot)
    }

    private func setRunning(_ id: UUID?) {
        guard id != running else { return }
        running = id
        defaults.set(id?.uuidString, forKey: Self.runningKey)
    }

    private func setLastEnded(_ ended: WatchEndedWorkout) {
        lastEnded = ended
        do {
            defaults.set(try JSONEncoder().encode(ended), forKey: Self.lastEndedKey)
        } catch {
            Self.log.error("Saving the last ended workout failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
