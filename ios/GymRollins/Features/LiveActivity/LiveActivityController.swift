import Foundation
import GymCore
import Observation
import os

/// An activity that already exists (for example one left from before the app was relaunched).
struct RunningWorkoutActivity: Equatable, Sendable {
    let id: String
    let workoutId: UUID
}

/// The ActivityKit calls the controller needs, behind a protocol so it can be tested with a fake.
@MainActor
protocol WorkoutActivityClient: AnyObject {
    func running() -> [RunningWorkoutActivity]
    /// Requests a new activity and returns its id; throws when Live Activities are off or unavailable.
    func start(_ attributes: WorkoutActivityAttributes, state: WorkoutActivityAttributes.ContentState) throws -> String
    func update(id: String, state: WorkoutActivityAttributes.ContentState) async
    func end(id: String) async
}

/// What the activity should show right now; nil when no workout is in progress.
struct WorkoutActivitySnapshot: Equatable, Sendable {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutActivityAttributes.ContentState

    @MainActor
    static func make(session: WorkoutSession?, now: Date, unit: WeightUnit,
                     exercise: (String) -> Exercise?) -> WorkoutActivitySnapshot? {
        guard let session, !session.isAbandoned,
              let state = WorkoutActivityContent.state(workout: session.workout, currentEntryId: session.currentEntryId,
                                                       rest: session.rest, now: now, unit: unit, exercise: exercise)
        else { return nil }
        return WorkoutActivitySnapshot(
            attributes: WorkoutActivityAttributes(workoutId: session.workout.id, workoutName: session.workout.name),
            state: state)
    }
}

/// Keeps one Live Activity in step with the in-progress workout: starts it for a new workout (adopting one left for
/// the same workout after a relaunch and ending any other), updates it when what it shows changes, and ends it when
/// the workout is finished, discarded or abandoned. ActivityKit calls run one after another, in order.
@MainActor
final class LiveActivityController {
    private let client: WorkoutActivityClient
    private var current: (id: String, workoutId: UUID, state: WorkoutActivityAttributes.ContentState?)?
    private var reconciled = false
    private var queue: Task<Void, Never>?
    private var source: (@MainActor @Sendable () -> WorkoutActivitySnapshot?)?
    private static let log = Logger(subsystem: "com.rollins.gymrollins", category: "live-activity")

    init(client: WorkoutActivityClient) {
        self.client = client
    }

    /// Applies `source()` now and again whenever anything it read (Observation) changes.
    func observe(_ source: @escaping @MainActor @Sendable () -> WorkoutActivitySnapshot?) {
        self.source = source
        track()
    }

    /// Re-applies the observed source and waits until ActivityKit has the result (an intent's `perform` awaits this
    /// so the lock screen is updated before the app can be suspended again).
    func refresh() async {
        if let source { apply(source()) }
        await flush()
    }

    /// Waits for the queued ActivityKit calls.
    func flush() async {
        await queue?.value
    }

    func apply(_ desired: WorkoutActivitySnapshot?) {
        if !reconciled { reconcile(with: desired) }
        guard let desired else {
            if let current { enqueueEnd(current.id) }
            current = nil
            return
        }
        if let current, current.workoutId == desired.attributes.workoutId {
            guard current.state != desired.state else { return }
            self.current = (current.id, current.workoutId, desired.state)
            enqueue { [client] in await client.update(id: current.id, state: desired.state) }
            return
        }
        if let current { enqueueEnd(current.id) }
        current = nil
        do {
            let id = try client.start(desired.attributes, state: desired.state)
            current = (id, desired.attributes.workoutId, desired.state)
        } catch {
            Self.log.error("Live Activity start failed: \(error.localizedDescription, privacy: .public)")
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

    /// Once per launch: keep the activity already showing this workout, end every other one.
    private func reconcile(with desired: WorkoutActivitySnapshot?) {
        reconciled = true
        for activity in client.running() {
            if current == nil, activity.workoutId == desired?.attributes.workoutId {
                current = (activity.id, activity.workoutId, nil)
            } else {
                enqueueEnd(activity.id)
            }
        }
    }

    private func enqueueEnd(_ id: String) {
        enqueue { [client] in await client.end(id: id) }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            await work()
        }
    }
}
