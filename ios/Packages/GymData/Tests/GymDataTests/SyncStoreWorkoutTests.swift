import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

func sampleWorkout(id: UUID = UUID(), name: String = "Push", at date: Date, weightKg: Double = 60) -> Workout {
    Workout(id: id, startedAt: date, endedAt: date.addingTimeInterval(3_600), name: name, entries: [
        WorkoutEntry(exerciseId: "bench", sets: [
            WorkoutSet(weightKg: weightKg, reps: 8, done: true, completedAt: date),
            WorkoutSet(weightKg: weightKg, reps: 7, done: true, completedAt: date),
        ]),
    ])
}

@MainActor
@Suite struct SyncStoreWorkoutTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    private func remoteRow(_ w: Workout, edit: Date, server: Date, deleted: Date? = nil) -> SyncRow<WorkoutSnapshot> {
        SyncRow(value: WorkoutSnapshot(workout: w, records: [], volumeKg: WorkoutMetrics.volumeKg(w)),
                clientUpdatedAt: edit, deletedAt: deleted, serverUpdatedAt: server)
    }

    /// Saves a workout and marks it synced at `server`.
    private func savedAndSynced(_ w: Workout, server: Date) throws {
        try f.workouts.save(w)
        try f.store.markSynced(.workouts, id: w.id.uuidString, clientUpdatedAt: f.clock.now, serverUpdatedAt: server)
    }

    @Test func dirtyWorkoutsCarryRecordsAndVolume() throws {
        defer { f.tearDown() }
        let w = sampleWorkout(at: f.clock.now)
        let pr = PersonalRecord(exerciseId: "bench", kind: .e1RM, valueKg: 75, reps: nil, weightKg: nil, previousKg: 70)
        try f.workouts.save(w, records: [pr])
        let row = try #require(f.store.dirtyWorkouts().first)
        #expect(row.value.workout == w)
        #expect(row.value.records == [pr])
        #expect(row.value.volumeKg == WorkoutMetrics.volumeKg(w))
        #expect(row.clientUpdatedAt == f.clock.now)
    }

    // Rule 5
    @Test func activeWorkoutIsNeverPushedNorOverwritten() throws {
        defer { f.tearDown() }
        let active = sampleWorkout(name: "Live", at: f.clock.now)
        try f.workouts.saveActive(active, pausedAt: nil)
        #expect(try f.store.dirtyWorkouts().isEmpty)

        let remote = sampleWorkout(id: active.id, name: "Remote", at: f.clock.now)
        let conflicts = try f.store.applyRemote(workouts: [remoteRow(remote, edit: f.clock.now, server: f.clock.now)])
        #expect(conflicts.isEmpty)
        #expect(try f.workouts.active()?.name == "Live")
    }

    @Test func remoteWorkoutIsInsertedCleanWithRecords() throws {
        defer { f.tearDown() }
        let w = sampleWorkout(at: f.clock.now)
        let pr = PersonalRecord(exerciseId: "bench", kind: .volume, valueKg: 900, reps: nil, weightKg: nil, previousKg: 800)
        let row = SyncRow(value: WorkoutSnapshot(workout: w, records: [pr], volumeKg: 960), clientUpdatedAt: f.clock.now,
                          serverUpdatedAt: f.clock.now)
        #expect(try f.store.applyRemote(workouts: [row]).isEmpty)
        #expect(try f.workouts.workout(w.id) == w)
        #expect(try f.workouts.records(for: w.id) == [pr])
        #expect(try f.workouts.recent(limit: 5).count == 1)
        #expect(try f.store.dirtyWorkouts().isEmpty)
    }

    @Test func cleanWorkoutIsOverwrittenAndTombstoneHidesIt() throws {
        defer { f.tearDown() }
        let w = sampleWorkout(at: f.clock.now)
        try savedAndSynced(w, server: f.clock.now)
        f.clock.advance()
        let edited = sampleWorkout(id: w.id, name: "Edited", at: w.startedAt, weightKg: 70)
        try f.store.applyRemote(workouts: [remoteRow(edited, edit: f.clock.now, server: f.clock.now)])
        #expect(try f.workouts.workout(w.id) == edited)
        f.clock.advance()
        try f.store.applyRemote(workouts: [remoteRow(edited, edit: f.clock.now, server: f.clock.now, deleted: f.clock.now)])
        #expect(try f.workouts.workout(w.id) == nil)
        #expect(try f.store.dirtyWorkouts().isEmpty)
    }

    // Rule 3 for workouts: dirty locally and changed remotely -> conflict, local untouched.
    @Test func dirtyWorkoutChangedRemotelyIsAConflict() throws {
        defer { f.tearDown() }
        let w = sampleWorkout(at: f.clock.now)
        let firstServer = f.clock.now
        try savedAndSynced(w, server: firstServer)
        f.clock.advance()
        try f.workouts.save(sampleWorkout(id: w.id, name: "Mine", at: w.startedAt))
        let theirs = sampleWorkout(id: w.id, name: "Theirs", at: w.startedAt)
        let conflicts = try f.store.applyRemote(workouts: [
            remoteRow(theirs, edit: f.clock.now.addingTimeInterval(5), server: firstServer.addingTimeInterval(30)),
        ])
        #expect(conflicts == [w.id])
        #expect(try f.workouts.workout(w.id)?.name == "Mine")
        #expect(try f.store.dirtyWorkouts().count == 1)
    }

    /// The echo of a version this device already knows (same server time) is not a remote change.
    @Test func dirtyWorkoutWithUnchangedRemoteIsNotAConflict() throws {
        defer { f.tearDown() }
        let w = sampleWorkout(at: f.clock.now)
        let server = f.clock.now
        try savedAndSynced(w, server: server)
        f.clock.advance()
        try f.workouts.save(sampleWorkout(id: w.id, name: "Mine", at: w.startedAt))
        let conflicts = try f.store.applyRemote(workouts: [remoteRow(w, edit: w.startedAt, server: server)])
        #expect(conflicts.isEmpty)
        #expect(try f.workouts.workout(w.id)?.name == "Mine")
    }

    @Test func resolveConflictKeepingLocalBumpsEditTime() throws {
        defer { f.tearDown() }
        let w = sampleWorkout(name: "Mine", at: f.clock.now)
        try f.workouts.save(w)
        f.clock.advance(120)
        try f.store.resolveWorkoutConflict(id: w.id, keepLocal: true, remote: nil)
        let row = try #require(f.store.dirtyWorkouts().first)
        #expect(row.clientUpdatedAt == f.clock.now)
        #expect(row.value.workout.name == "Mine")
    }

    @Test func resolveConflictKeepingRemoteAppliesItClean() throws {
        defer { f.tearDown() }
        let w = sampleWorkout(name: "Mine", at: f.clock.now)
        try f.workouts.save(w)
        let theirs = sampleWorkout(id: w.id, name: "Theirs", at: w.startedAt, weightKg: 80)
        let server = f.clock.now.addingTimeInterval(10)
        try f.store.resolveWorkoutConflict(id: w.id, keepLocal: false,
                                           remote: remoteRow(theirs, edit: server, server: server))
        #expect(try f.workouts.workout(w.id) == theirs)
        #expect(try f.store.dirtyWorkouts().isEmpty)
    }
}
