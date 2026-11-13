import Foundation
import GymCore
import GymData
import GymSync
import Testing
@testable import GymRollins

/// A server that holds one plan with an agent's kg weight (bench at 20.3 kg, which shows as 44.8 lb). It serves it on
/// the first pull and keeps every push, counting the routines it was sent.
private actor PlanServer: SyncTransport {
    static let pushId = UUID(uuidString: "38383838-3838-3838-3838-383838383838")!
    private(set) var pushedRoutines: [RoutineDTO] = []

    private func ack(_ id: String) -> RowAck { RowAck(id: id, updatedAt: Date()) }

    func push(profile: ProfileDTO) async throws -> RowAck? { ack(SyncStore.profileSyncID) }
    func push(customExercises: [CustomExerciseDTO]) async throws -> [RowAck] { customExercises.map { ack($0.id) } }
    func push(exercisePrefs: [ExercisePrefDTO]) async throws -> [RowAck] { exercisePrefs.map { ack($0.exerciseId) } }
    func push(routines: [RoutineDTO]) async throws -> [RowAck] {
        pushedRoutines += routines
        return routines.map { ack($0.id.uuidString.lowercased()) }
    }
    func push(weekdays: [WeekdayDTO]) async throws -> [RowAck] { weekdays.map { ack(String($0.weekday)) } }
    func push(bodyweight: [BodyweightDTO]) async throws -> [RowAck] {
        bodyweight.map { ack($0.id.uuidString.lowercased()) }
    }
    func push(workout: WorkoutDTO) async throws -> WorkoutPushResult { .ok(updatedAt: Date()) }

    func pullProfile(since: Date?) async throws -> [ProfileDTO] { [] }
    func pullCustomExercises(since: Date?) async throws -> [CustomExerciseDTO] { [] }
    func pullExercisePrefs(since: Date?) async throws -> [ExercisePrefDTO] { [] }
    func pullRoutines(since: Date?) async throws -> [RoutineDTO] {
        guard since == nil else { return [] }
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        let push = Routine(id: Self.pushId, name: "Push", exercises: [
            RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, weightKg: 20.3),
        ])
        return [RoutineDTO(SyncRow(value: RoutineSnapshot(routine: push, position: 0), clientUpdatedAt: stamp,
                                   serverUpdatedAt: stamp))]
    }
    func pullWeekdays(since: Date?) async throws -> [WeekdayDTO] { [] }
    func pullBodyweight(since: Date?) async throws -> [BodyweightDTO] { [] }
    func pullWorkouts(since: Date?) async throws -> [WorkoutDTO] { [] }
    func fetchWorkout(id: UUID) async throws -> WorkoutDTO? { nil }
    func pendingProposals() async throws -> [PulledProposal] { [] }
    func resolveProposal(id: UUID, status: String, appliedChangeIds: [String], at: Date) async throws {}
}

/// Plan 38's cleanup on a reinstall or a new sign-in: the launch finds no plan, so the cleanup waits, and it runs on
/// the plan the first pull brings.
@MainActor
@Suite struct PlanWeightsAfterPullTests {
    @Test func theFirstPullsKgPlanWeightsGetTheirPoundNumbersAndSyncOnce() async throws {
        let defaults = try #require(UserDefaults(suiteName: "PlanWeightsAfterPullTests.\(UUID())"))
        let server = PlanServer()
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-noSeed"]), defaults: defaults,
                                     makeSync: { store, now in
                                         SyncCoordinator(auth: nil, store: store, now: now,
                                                         makeTransport: { _ in server })
                                     })
        try env.profiles.save(Profile(unit: .lb))
        env.reloadProfile()
        env.cleanUpPlanWeightsOnce() // a launch in lb with nothing pulled yet
        #expect(try env.routines.all().isEmpty)
        #expect(!defaults.bool(forKey: PlanWeightsLbCleanup.flagKey))

        await env.sync.start() // pulls the plan; applying it runs the cleanup
        env.sync.setActive(false)
        let bench = try #require(try env.routines.routine(PlanServer.pushId)?.exercises.first)
        #expect(bench.weight == PoundWeight.entered(45, unit: .lb), "20.41 kg, 45 lb")
        #expect(defaults.bool(forKey: PlanWeightsLbCleanup.flagKey))

        await env.sync.syncNow() // the cleaned plan goes up
        let pushed = await server.pushedRoutines
        #expect(pushed.map(\.id) == [PlanServer.pushId], "pushed once, and the next round finds nothing to clean")
        #expect(pushed.first?.exercises.first?.weightLb == 45)
    }
}
