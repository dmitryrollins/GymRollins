import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymSync

@MainActor
final class Clock {
    var now = SyncDate.parse("2026-09-26T12:00:00Z")!
    func advance(_ seconds: TimeInterval = 60) { now = now.addingTimeInterval(seconds) }
}

@MainActor
struct EngineFixture {
    let container: ModelContainer
    let clock = Clock()
    let suiteName = "test-\(UUID())"
    let defaults: UserDefaults
    let server = FakeTransport()
    let store: SyncStore
    let engine: SyncEngine

    init() throws {
        container = try GymStore.container(inMemory: true)
        defaults = UserDefaults(suiteName: suiteName)!
        let clock = clock
        store = SyncStore(context: container.mainContext, defaults: defaults, now: { clock.now })
        engine = SyncEngine(store: store, transport: server, now: { clock.now })
    }

    var routines: RoutineRepository { RoutineRepository(context: container.mainContext, now: { [clock] in clock.now }) }
    var workouts: WorkoutRepository { WorkoutRepository(context: container.mainContext, now: { [clock] in clock.now }) }
    var body: BodyRepository { BodyRepository(context: container.mainContext, now: { [clock] in clock.now }) }
    var profiles: ProfileRepository { ProfileRepository(context: container.mainContext, now: { [clock] in clock.now }) }
    var custom: CustomExerciseRepository {
        CustomExerciseRepository(context: container.mainContext, now: { [clock] in clock.now })
    }

    func tearDown() { defaults.removePersistentDomain(forName: suiteName) }
}

func workout(id: UUID = UUID(), name: String, at date: Date) -> Workout {
    Workout(id: id, startedAt: date, endedAt: date.addingTimeInterval(3_000), name: name, entries: [
        WorkoutEntry(exerciseId: "bench", sets: [
            WorkoutSet(weightKg: 60, reps: 8, done: true),
            WorkoutSet(weightKg: 60, reps: 8, done: true),
            WorkoutSet(weightKg: 60, reps: 7, done: true),
        ]),
    ])
}

@MainActor
@Suite struct SyncEngineTests {
    let f: EngineFixture
    init() throws { f = try EngineFixture() }

    // (1)
    @Test func firstSyncPushesAllDirtyRowsAndMarksThemSynced() async throws {
        defer { f.tearDown() }
        try f.profiles.save(Profile(unit: .kg))
        let ex = try f.custom.create(name: "Sled", bodyPart: "legs", equipment: "sled", target: "quads", mode: .reps,
                                     bilateral: false)
        let routine = Routine(name: "Push", exercises: [RoutineExercise(exerciseId: "bench", sets: 3, reps: 8)])
        try f.routines.upsert(routine)
        try f.routines.setSchedule(weekday: 1, routineId: routine.id)
        try f.body.add(BodyweightEntry(date: f.clock.now, weightKg: 81))
        let w = workout(name: "Push", at: f.clock.now)
        try f.workouts.save(w)

        await f.engine.sync()

        #expect(f.engine.status == .idle)
        #expect(f.engine.lastSyncedAt == f.clock.now)
        #expect(await f.server.profile?.unit == "kg")
        #expect(await f.server.customExercises[ex.id]?.n == "Sled")
        #expect(await f.server.routines[routine.id]?.exercises.count == 1)
        #expect(await f.server.weekdays[1]?.routineId == routine.id)
        #expect(await f.server.bodyweight.count == 1)
        #expect(await f.server.workouts[w.id]?.entries.first?.sets.count == 3)
        #expect(try f.store.dirtyProfile() == nil)
        #expect(try f.store.dirtyCustomExercises().isEmpty)
        #expect(try f.store.dirtyRoutines().isEmpty)
        #expect(try f.store.dirtyWeekdays().isEmpty)
        #expect(try f.store.dirtyBodyweight().isEmpty)
        #expect(try f.store.dirtyWorkouts().isEmpty)
    }

    // (2)
    @Test func remoteOnlyRowsArePulled() async throws {
        defer { f.tearDown() }
        let routine = Routine(name: "Legs", exercises: [RoutineExercise(exerciseId: "squat", sets: 5, reps: 5)])
        try await f.server.seed(routine: RoutineDTO(SyncRow(value: RoutineSnapshot(routine: routine, position: 0),
                                                            clientUpdatedAt: f.clock.now)))
        let w = workout(name: "Remote", at: f.clock.now)
        try await f.server.seed(workout: WorkoutDTO(SyncRow(value: WorkoutSnapshot(workout: w, records: [], volumeKg: 1_380),
                                                            clientUpdatedAt: f.clock.now)))
        let bw = BodyweightEntry(date: f.clock.now, weightKg: 82)
        try await f.server.seed(bodyweight: BodyweightDTO(SyncRow(value: bw, clientUpdatedAt: f.clock.now)))

        await f.engine.sync()

        #expect(f.engine.status == .idle)
        #expect(try f.routines.all() == [routine])
        #expect(try f.workouts.workout(w.id) == w)
        #expect(try f.body.entries(since: nil) == [bw])
        #expect(try f.store.dirtyRoutines().isEmpty)
        #expect(try f.store.dirtyWorkouts().isEmpty)
    }

    /// Syncs a workout, then edits it locally and (later) on another device.
    private func makeConflict() async throws -> UUID {
        let w = workout(name: "Original", at: f.clock.now)
        try f.workouts.save(w)
        await f.engine.sync()
        f.clock.advance()
        try f.workouts.save(workout(id: w.id, name: "Mine", at: w.startedAt))
        let otherDeviceEdit = f.clock.now.addingTimeInterval(30)
        let theirs = workout(id: w.id, name: "Theirs", at: w.startedAt)
        try await f.server.seed(workout: WorkoutDTO(SyncRow(value: WorkoutSnapshot(workout: theirs, records: [], volumeKg: 0),
                                                            clientUpdatedAt: otherDeviceEdit)))
        await f.engine.sync()
        return w.id
    }

    // (3)
    @Test func concurrentEditsConflictAndKeepLocalWins() async throws {
        defer { f.tearDown() }
        let id = try await makeConflict()
        #expect(f.engine.status == .conflicts([id]))
        #expect(try f.workouts.workout(id)?.name == "Mine")
        #expect(await f.server.workouts[id]?.name == "Theirs")

        f.clock.advance()
        await f.engine.resolve(conflict: id, keepLocal: true)

        #expect(f.engine.status == .idle)
        #expect(await f.server.workouts[id]?.name == "Mine")
        #expect(try f.store.dirtyWorkouts().isEmpty)
    }

    /// Codex P1: a local edit made AFTER another device's edit (newer wall clock) but on the older base version is a
    /// conflict, not a silent overwrite; only the explicit "Keep this iPhone's" forces it.
    @Test func newerLocalEditOnStaleBaseConflictsInsteadOfOverwriting() async throws {
        defer { f.tearDown() }
        let w = workout(name: "Original", at: f.clock.now)
        try f.workouts.save(w)
        await f.engine.sync()
        let theirs = workout(id: w.id, name: "Theirs", at: w.startedAt)
        try await f.server.seed(workout: WorkoutDTO(SyncRow(value: WorkoutSnapshot(workout: theirs, records: [], volumeKg: 0),
                                                            clientUpdatedAt: f.clock.now.addingTimeInterval(30))))
        f.clock.advance(120) // edited here later than the other device, but from the version before its edit
        try f.workouts.save(workout(id: w.id, name: "Mine", at: w.startedAt))

        await f.engine.sync()

        #expect(f.engine.status == .conflicts([w.id]))
        #expect(await f.server.workouts[w.id]?.name == "Theirs")
        #expect(await f.server.forcedWorkoutPushes == 0)
        #expect(try f.workouts.workout(w.id)?.name == "Mine")

        await f.engine.resolve(conflict: w.id, keepLocal: true)
        #expect(f.engine.status == .idle)
        #expect(await f.server.workouts[w.id]?.name == "Mine")
        #expect(await f.server.forcedWorkoutPushes == 1)
        #expect(try f.store.dirtyWorkouts().isEmpty)
    }

    /// The push carries the server version this device last saw as its base.
    @Test func workoutPushCarriesTheLastSeenServerVersionAsBase() async throws {
        defer { f.tearDown() }
        let w = workout(name: "Original", at: f.clock.now)
        try f.workouts.save(w)
        await f.engine.sync()
        #expect(await f.server.lastWorkoutBase == .some(nil))
        let v1 = await f.server.workouts[w.id]?.updatedAt
        f.clock.advance()
        try f.workouts.save(workout(id: w.id, name: "Edited", at: w.startedAt))
        await f.engine.sync()
        #expect(await f.server.lastWorkoutBase == .some(v1))
        #expect(f.engine.status == .idle)
        #expect(await f.server.workouts[w.id]?.name == "Edited")
    }

    /// Disconnect Claude pushes the profile at once and learns whether the server stored it.
    @Test func pushProfileNowStoresTheProfileOrThrows() async throws {
        defer { f.tearDown() }
        try f.profiles.setMcpPermissions(readWorkouts: false, readBody: false, readPlan: false, propose: false,
                                         autoApply: false)
        await f.server.fail(with: URLError(.notConnectedToInternet))
        await #expect(throws: URLError.self) { try await f.engine.pushProfileNow() }
        #expect(try f.store.dirtyProfile() != nil)
        #expect(await f.server.profile == nil)

        await f.server.fail(with: nil)
        try await f.engine.pushProfileNow()
        #expect(try f.store.dirtyProfile() == nil)
        #expect(await f.server.profile?.mcpReadWorkouts == false)
        try await f.engine.pushProfileNow() // nothing dirty: already stored
    }

    @Test func pushProfileNowThrowsWhenTheServerKeptANewerEdit() async throws {
        defer { f.tearDown() }
        try f.profiles.setMcpPermissions(readWorkouts: false, readBody: false, readPlan: false, propose: false,
                                         autoApply: false)
        var newer = ProfileSnapshot()
        newer.mcpReadWorkouts = true
        try await f.server.seed(profile: ProfileDTO(SyncRow(value: newer, clientUpdatedAt: f.clock.now.addingTimeInterval(60))))
        await #expect(throws: ProfilePushError.self) { try await f.engine.pushProfileNow() }
    }

    @Test func concurrentEditsConflictAndKeepOtherAppliesRemote() async throws {
        defer { f.tearDown() }
        let id = try await makeConflict()
        await f.engine.resolve(conflict: id, keepLocal: false)

        #expect(f.engine.status == .idle)
        #expect(try f.workouts.workout(id)?.name == "Theirs")
        #expect(try f.store.dirtyWorkouts().isEmpty)
        await f.engine.sync()
        #expect(f.engine.status == .idle)
        #expect(await f.server.workouts[id]?.name == "Theirs")
    }

    // (4)
    @Test func offlineKeepsLocalDataDirty() async throws {
        defer { f.tearDown() }
        let routine = Routine(name: "Push")
        try f.routines.upsert(routine)
        await f.server.fail(with: URLError(.notConnectedToInternet))

        await f.engine.sync()

        #expect(f.engine.status == .offline)
        #expect(f.engine.lastSyncedAt == nil)
        #expect(try f.routines.all() == [routine])
        #expect(try f.store.dirtyRoutines().count == 1)

        await f.server.fail(with: nil)
        await f.engine.sync()
        #expect(f.engine.status == .idle)
        #expect(try f.store.dirtyRoutines().isEmpty)
    }

    // (5)
    @Test func tombstonedRoutineSyncsAsDeletedAndStaysHidden() async throws {
        defer { f.tearDown() }
        let routine = Routine(name: "Push")
        try f.routines.upsert(routine)
        await f.engine.sync()
        f.clock.advance()
        try f.routines.delete(routine.id)

        await f.engine.sync()

        #expect(await f.server.routines[routine.id]?.deletedAt == f.clock.now)
        #expect(try f.routines.all().isEmpty)
        #expect(try f.store.dirtyRoutines().isEmpty)
    }

    // (6)
    @Test func cursorAdvancesAndSecondSyncPullsNothingNew() async throws {
        defer { f.tearDown() }
        try f.routines.upsert(Routine(name: "Push"))
        try await f.server.seed(routine: RoutineDTO(SyncRow(value: RoutineSnapshot(routine: Routine(name: "Legs"), position: 1),
                                                            clientUpdatedAt: f.clock.now)))
        await f.engine.sync()
        let newest = await f.server.routines.values.compactMap(\.updatedAt).max()
        #expect(f.store.cursor(for: .routines) == newest)
        #expect(try f.routines.all().count == 2)

        let pulledBefore = await f.server.pulledRows
        await f.engine.sync()
        #expect(await f.server.pulledRows == pulledBefore)
        #expect(f.engine.status == .idle)
    }

    @Test func remoteChangeCountBumpsOnlyWhenRowsArePulled() async throws {
        defer { f.tearDown() }
        await f.engine.sync()
        #expect(f.engine.remoteChangeCount == 0)

        try await f.server.seed(routine: RoutineDTO(SyncRow(value: RoutineSnapshot(routine: Routine(name: "Legs"), position: 0),
                                                            clientUpdatedAt: f.clock.now)))
        await f.engine.sync()
        #expect(f.engine.remoteChangeCount == 1)

        await f.engine.sync()
        #expect(f.engine.remoteChangeCount == 1)
    }

    @Test func remoteWorkoutReturnsTheOtherDevicesVersion() async throws {
        defer { f.tearDown() }
        let id = try await makeConflict()
        let before = f.engine.remoteChangeCount
        #expect(try await f.engine.remoteWorkout(id: id)?.workout.name == "Theirs")
        #expect(try await f.engine.remoteWorkout(id: UUID()) == nil)

        await f.engine.resolve(conflict: id, keepLocal: false)
        #expect(f.engine.remoteChangeCount == before + 1)
    }

    @Test func neverRunsTwoSyncsAtOnce() async throws {
        defer { f.tearDown() }
        try f.routines.upsert(Routine(name: "Push"))
        let before = await f.server.pushCalls
        async let first: Void = f.engine.sync()
        async let second: Void = f.engine.sync()
        _ = await (first, second)
        // One sync = 1 routine push + 6 pulls (pulls don't count) -> exactly one push call.
        #expect(await f.server.pushCalls - before == 1)
    }

    /// A local edit older than the server's is rejected by the LWW guard (no ack); the pull then replaces it.
    @Test func olderLocalEditLosesToNewerServerEdit() async throws {
        defer { f.tearDown() }
        let routine = Routine(name: "Push")
        try f.routines.upsert(Routine(id: routine.id, name: "Mine"))
        try await f.server.seed(routine: RoutineDTO(SyncRow(value: RoutineSnapshot(routine: Routine(id: routine.id, name: "Theirs"),
                                                                                   position: 0),
                                                            clientUpdatedAt: f.clock.now.addingTimeInterval(60))))
        await f.engine.sync()
        #expect(f.engine.status == .idle)
        #expect(try f.routines.routine(routine.id)?.name == "Theirs")
        #expect(try f.store.dirtyRoutines().isEmpty)
    }
}
