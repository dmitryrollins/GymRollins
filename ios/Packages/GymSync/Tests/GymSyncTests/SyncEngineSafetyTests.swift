import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymSync

/// Rounds stopped by shutdown can't touch the store; records the server refuses don't block the rest of sync.
@MainActor
@Suite struct SyncEngineSafetyTests {
    let f: EngineFixture
    init() throws { f = try EngineFixture() }

    private func remoteRoutine(_ name: String) -> RoutineDTO {
        let routine = Routine(name: name, exercises: [RoutineExercise(exerciseId: "bench", sets: 3, reps: 8)])
        return RoutineDTO(SyncRow(value: RoutineSnapshot(routine: routine, position: 0), clientUpdatedAt: f.clock.now))
    }

    // MARK: Shutdown

    @Test func responseArrivingAfterShutdownIsDropped() async throws {
        defer { f.tearDown() }
        try await f.server.seed(routine: remoteRoutine("Other device"))
        await f.server.holdNextPull()

        let round = Task { await f.engine.sync() }
        try await waitFor { await f.server.isPullSuspended }

        let shutdown = Task { await f.engine.shutdown() }
        try await waitFor { f.engine.isShutDown } // shutdown began before the response arrives
        await f.server.releasePull()
        await shutdown.value
        await round.value

        #expect(try f.routines.all().isEmpty)
        #expect(SyncEntity.allCases.allSatisfy { f.store.cursor(for: $0) == nil })
        #expect(f.engine.remoteChangeCount == 0)
    }

    @Test func shutDownEngineNeverSyncsAgain() async throws {
        defer { f.tearDown() }
        try await f.server.seed(routine: remoteRoutine("Other device"))
        await f.engine.shutdown()
        await f.engine.sync()
        #expect(try f.routines.all().isEmpty)
        #expect(await f.server.pushCalls == 0)
    }

    // MARK: Rejected records

    @Test func rejectedRoutineIsRecordedAndTheRestSyncs() async throws {
        defer { f.tearDown() }
        let good = Routine(name: "Push", exercises: [])
        let bad = Routine(name: "Pull", exercises: [])
        try f.routines.upsert(good)
        try f.routines.upsert(bad)
        try f.body.add(BodyweightEntry(date: f.clock.now, weightKg: 81))
        let w = workout(name: "Push", at: f.clock.now)
        try f.workouts.save(w)
        await f.server.reject(ids: [bad.id.uuidString])
        try await f.server.seed(routine: remoteRoutine("From another device"))

        await f.engine.sync()

        #expect(f.engine.status == .idle)
        #expect(await f.server.routines[good.id] != nil)
        #expect(await f.server.routines[bad.id] == nil)
        #expect(await f.server.bodyweight.count == 1)
        #expect(await f.server.workouts[w.id] != nil)
        // The pull still ran.
        #expect(try f.routines.all().contains { $0.name == "From another device" })
        let failures = f.store.syncFailures()
        #expect(failures.map(\.entity) == [.routines])
        #expect(failures.first?.id.lowercased() == bad.id.uuidString.lowercased())
        #expect(failures.first?.message.contains("check constraint") == true)
        #expect(try f.store.dirtyRoutines().map(\.value.routine.id) == [bad.id])

        // The same edit isn't retried on the next round.
        let callsBefore = await f.server.pushCalls
        await f.engine.sync()
        #expect(await f.server.pushCalls == callsBefore)

        // Editing it again retries; once accepted the failure clears.
        await f.server.reject(ids: [])
        f.clock.advance()
        try f.routines.upsert(Routine(id: bad.id, name: "Pull fixed", exercises: []))
        await f.engine.sync()
        #expect(await f.server.routines[bad.id]?.name == "Pull fixed")
        #expect(f.store.syncFailures().isEmpty)
    }

    @Test func rejectedWorkoutDoesNotBlockOtherWorkouts() async throws {
        defer { f.tearDown() }
        let bad = workout(name: "Bad", at: f.clock.now)
        let good = workout(name: "Good", at: f.clock.now.addingTimeInterval(3_600))
        try f.workouts.save(bad)
        try f.workouts.save(good)
        await f.server.reject(ids: [bad.id.uuidString])

        await f.engine.sync()

        #expect(f.engine.status == .idle)
        #expect(await f.server.workouts[good.id] != nil)
        #expect(f.store.syncFailures().map(\.id) == [bad.id.uuidString])
    }

    @Test func networkFailureIsNotRecordedAsARejection() async throws {
        defer { f.tearDown() }
        try f.routines.upsert(Routine(name: "Push", exercises: []))
        await f.server.fail(with: URLError(.notConnectedToInternet))
        await f.engine.sync()
        #expect(f.engine.status == .offline)
        #expect(f.store.syncFailures().isEmpty)
    }
}

/// Polls `condition` (up to 2 s).
@MainActor
func waitFor(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for condition")
}
