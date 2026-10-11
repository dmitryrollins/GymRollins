import Foundation
import GymCore
import Testing
@testable import GymRollins

@MainActor
final class FakeActivityClient: WorkoutActivityClient {
    enum Call: Equatable {
        case start(UUID, WorkoutActivityAttributes.ContentState)
        case update(String, WorkoutActivityAttributes.ContentState)
        case end(String)
    }
    struct Disabled: Error {}

    var calls: [Call] = []
    var existing: [RunningWorkoutActivity] = []
    var failStart = false
    private var nextId = 0

    func running() -> [RunningWorkoutActivity] { existing }

    func start(_ attributes: WorkoutActivityAttributes, state: WorkoutActivityAttributes.ContentState) throws -> String {
        if failStart { throw Disabled() }
        nextId += 1
        calls.append(.start(attributes.workoutId, state))
        return "activity-\(nextId)"
    }

    func update(id: String, state: WorkoutActivityAttributes.ContentState) async { calls.append(.update(id, state)) }
    func end(id: String) async { calls.append(.end(id)) }
}

@MainActor
@Suite struct LiveActivityControllerTests {
    let workoutId = UUID()

    private func state(_ label: String, rest: Date? = nil) -> WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(exerciseName: "Bench", setLabel: label, setDetail: "135 lb × 8",
                                               restStartedAt: rest, restEndsAt: rest?.addingTimeInterval(90),
                                               canLogSet: true, entryId: UUID(), setId: UUID(), isComplete: false)
    }

    private func snapshot(_ label: String, workout: UUID? = nil) -> WorkoutActivitySnapshot {
        WorkoutActivitySnapshot(attributes: WorkoutActivityAttributes(workoutId: workout ?? workoutId, workoutName: "Push"),
                                state: state(label))
    }

    @Test func startsOnceThenUpdatesOnlyOnChange() async {
        let client = FakeActivityClient()
        let controller = LiveActivityController(client: client)
        let first = snapshot("Set 1/3")
        controller.apply(first)
        controller.apply(first)
        let second = WorkoutActivitySnapshot(attributes: first.attributes, state: state("Set 2/3"))
        controller.apply(second)
        await controller.flush()
        #expect(client.calls == [.start(workoutId, first.state), .update("activity-1", second.state)])
    }

    @Test func endsWhenTheWorkoutGoesAway() async {
        let client = FakeActivityClient()
        let controller = LiveActivityController(client: client)
        controller.apply(snapshot("Set 1/3"))
        controller.apply(nil)
        controller.apply(nil)
        await controller.flush()
        #expect(client.calls.last == .end("activity-1"))
        #expect(client.calls.count == 2)
    }

    @Test func aNewWorkoutReplacesTheOldActivity() async {
        let client = FakeActivityClient()
        let controller = LiveActivityController(client: client)
        controller.apply(snapshot("Set 1/3"))
        let other = UUID()
        let next = snapshot("Set 1/4", workout: other)
        controller.apply(next)
        await controller.flush()
        // The new activity is requested right away; the old one's end is queued (ActivityKit's end is async).
        #expect(client.calls.count == 3)
        #expect(client.calls.contains(.end("activity-1")))
        #expect(client.calls.contains(.start(other, next.state)))
    }

    @Test func adoptsTheActivityLeftForTheSameWorkoutAndEndsOthers() async {
        let client = FakeActivityClient()
        client.existing = [RunningWorkoutActivity(id: "old", workoutId: UUID()),
                           RunningWorkoutActivity(id: "same", workoutId: workoutId)]
        let controller = LiveActivityController(client: client)
        let restored = snapshot("Set 2/3")
        controller.apply(restored)
        await controller.flush()
        #expect(client.calls == [.end("old"), .update("same", restored.state)])
    }

    @Test func endsLeftoverActivitiesWhenNoWorkoutIsInProgress() async {
        let client = FakeActivityClient()
        client.existing = [RunningWorkoutActivity(id: "old", workoutId: workoutId)]
        let controller = LiveActivityController(client: client)
        controller.apply(nil)
        await controller.flush()
        #expect(client.calls == [.end("old")])
    }

    @Test func aFailedStartIsRetriedOnTheNextChange() async {
        let client = FakeActivityClient()
        client.failStart = true
        let controller = LiveActivityController(client: client)
        controller.apply(snapshot("Set 1/3"))
        #expect(client.calls.isEmpty)
        client.failStart = false
        let next = snapshot("Set 2/3")
        controller.apply(next)
        await controller.flush()
        #expect(client.calls == [.start(workoutId, next.state)])
    }

    @Test func observationFollowsTheSessionAndRefreshAwaitsTheUpdate() async throws {
        let client = FakeActivityClient()
        let controller = LiveActivityController(client: client)
        let workout = Workout(startedAt: Date(timeIntervalSince1970: 1_000), name: "Push", entries: [
            WorkoutEntry(exerciseId: "x", sets: [WorkoutSet(weightKg: 60, reps: 8), WorkoutSet(weightKg: 60, reps: 8)])
        ])
        let session = WorkoutSession(
            workout: workout, clock: WorkoutClock(startedAt: workout.startedAt), restSeconds: 90, warmupRestSeconds: 60,
            notifier: NoopRestNotifier(), now: { Date(timeIntervalSince1970: 1_010) }, persist: { _, _ in },
            previousBests: { _ in nil }, saveFinished: { _, _ in }, discard: {})
        controller.observe {
            WorkoutActivitySnapshot.make(session: session, now: Date(timeIntervalSince1970: 1_010), unit: .kg,
                                         exercise: { _ in nil })
        }
        await controller.flush()
        #expect(client.calls.count == 1)

        let entry = session.workout.entries[0]
        session.perform(.logPlannedSet(workoutId: workout.id, entryId: entry.id, setId: entry.sets[0].id),
                        exercise: { _ in nil })
        await controller.refresh()
        guard case .update(_, let updated) = try #require(client.calls.last) else {
            Issue.record("expected an update, got \(client.calls)")
            return
        }
        #expect(updated.setLabel == "Set 2/2")
        #expect(updated.restEndsAt == Date(timeIntervalSince1970: 1_100))
    }
}
