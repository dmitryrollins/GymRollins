import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Plan 40: what Apple Health measured during a workout as a sync kind: dirty after a save, clean after the ack,
/// pulled by last write wins for a workout that is here, gone with its workout, wiped with the account and moved to
/// another server.
@MainActor
@Suite struct SyncStoreMeasurementTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    private var measurements: MeasurementRepository { MeasurementRepository(context: f.context) }

    /// A finished "Push + Biceps" of 58 min 20 s, synced when `synced` (a clean row a pulled deletion may replace).
    private func finished(synced: Bool = false) throws -> Workout {
        let start = f.clock.now.addingTimeInterval(-86_400)
        let workout = Workout(startedAt: start, endedAt: start.addingTimeInterval(3_500), name: "Push + Biceps")
        try f.workouts.save(workout)
        if synced {
            try f.store.markSynced(.workouts, id: workout.id.uuidString, clientUpdatedAt: f.clock.now,
                                   serverUpdatedAt: f.clock.now)
        }
        return workout
    }

    private func watch(_ workoutId: UUID, effort: Int? = 6, at date: Date? = nil) -> MeasurementSnapshot {
        MeasurementSnapshot(workoutId: workoutId, recordedBy: .watch, durationS: 3_500, activeKcal: 412,
                            totalKcal: 489, avgHr: 128, maxHr: 162, postHr: 124, effort: effort,
                            effortEstimated: false, clientUpdatedAt: date ?? f.clock.now)
    }

    private func pulled(_ s: MeasurementSnapshot, deletedAt: Date? = nil) -> SyncRow<MeasurementSnapshot> {
        SyncRow(value: s, clientUpdatedAt: s.clientUpdatedAt, deletedAt: deletedAt, serverUpdatedAt: f.clock.now)
    }

    @Test func savedNumbersAreDirtyUntilTheServerTakesThem() throws {
        defer { f.tearDown() }
        let workout = try finished()
        let numbers = watch(workout.id)
        try measurements.save(numbers)
        let rows = try f.store.dirtyWorkoutMeasurements()
        #expect(rows.map(\.value) == [numbers])
        #expect(rows.first?.clientUpdatedAt == numbers.clientUpdatedAt)
        #expect(rows.first?.deletedAt == nil)

        try f.store.markSynced(.workoutMeasurements, id: workout.id.uuidString.lowercased(),
                               clientUpdatedAt: numbers.clientUpdatedAt, serverUpdatedAt: f.clock.now)
        #expect(try f.store.dirtyWorkoutMeasurements().isEmpty)
    }

    @Test func aNewerPulledRowWinsOverADirtyOneAndAnOlderOneDoesNot() throws {
        defer { f.tearDown() }
        let workout = try finished()
        try measurements.save(watch(workout.id))
        try f.store.applyRemote(workoutMeasurements: [pulled(watch(workout.id, effort: 3,
                                                                    at: f.clock.now.addingTimeInterval(-60)))])
        #expect(try measurements.snapshot(for: workout.id)?.effort == 6)

        let newer = watch(workout.id, effort: 8, at: f.clock.now.addingTimeInterval(60))
        try f.store.applyRemote(workoutMeasurements: [pulled(newer)])
        #expect(try measurements.snapshot(for: workout.id) == newer)
        #expect(try f.store.dirtyWorkoutMeasurements().isEmpty)
    }

    @Test func aPulledRowIsKeptOnlyForAFinishedWorkoutThatIsHere() throws {
        defer { f.tearDown() }
        let deleted = try finished()
        try f.workouts.delete(deleted.id)
        let live = try finished()
        let unknown = watch(UUID()), gone = watch(deleted.id), kept = watch(live.id)
        try f.store.applyRemote(workoutMeasurements: [unknown, gone, kept].map { pulled($0) })
        #expect(try measurements.snapshot(for: unknown.workoutId) == nil)
        #expect(try measurements.snapshot(for: deleted.id) == nil)
        #expect(try measurements.snapshot(for: live.id) == kept)
        #expect(try f.context.fetchCount(FetchDescriptor<MeasurementRecord>()) == 1)
    }

    @Test func aWorkoutDeletedOnAnotherDeviceTakesItsNumbersAndSoDoesAPulledDeletion() throws {
        defer { f.tearDown() }
        let workout = try finished(synced: true)
        try measurements.save(watch(workout.id))
        let later = f.clock.now.addingTimeInterval(60)
        try f.store.applyRemote(workouts: [SyncRow(value: WorkoutSnapshot(workout: workout, records: [], volumeKg: 0),
                                                   clientUpdatedAt: later, deletedAt: later, serverUpdatedAt: later)])
        #expect(try measurements.snapshot(for: workout.id) == nil)

        let other = try finished()
        let numbers = watch(other.id)
        try measurements.save(numbers)
        try f.store.applyRemote(workoutMeasurements: [pulled(watch(other.id, at: later), deletedAt: later)])
        #expect(try measurements.snapshot(for: other.id) == nil)
    }

    @Test func theyAreAccountDataWipedOnSignOutAndMovedToAnotherServer() throws {
        defer { f.tearDown() }
        let workout = try finished(synced: true)
        let numbers = watch(workout.id)
        try measurements.save(numbers)
        try f.store.markSynced(.workoutMeasurements, id: workout.id.uuidString,
                               clientUpdatedAt: numbers.clientUpdatedAt, serverUpdatedAt: f.clock.now)
        f.store.syncedServer = "https://old.example"
        #expect(try f.store.moveToServer("https://new.example"))
        #expect(try f.store.dirtyWorkoutMeasurements().map(\.value) == [numbers])

        try f.store.resetAccountData()
        #expect(try f.context.fetchCount(FetchDescriptor<MeasurementRecord>()) == 0)
        #expect(try !f.store.hasLocalData())
    }

    @Test func numbersWaitForTheirWorkoutToReachTheServer() throws {
        defer { f.tearDown() }
        let workout = try finished()
        let numbers = watch(workout.id)
        try measurements.save(numbers)
        #expect(try f.store.dirtyWorkoutMeasurements().count == 1)
        #expect(try f.store.pushableWorkoutMeasurements().isEmpty, "the workout is still dirty")

        try f.store.markSynced(.workouts, id: workout.id.uuidString, clientUpdatedAt: f.clock.now,
                               serverUpdatedAt: f.clock.now)
        #expect(try f.store.pushableWorkoutMeasurements().map(\.value) == [numbers])
    }

    @Test func aPulledRowIsKeptForAnUnfinishedWorkoutButNotAMissingOrDeletedOne() throws {
        defer { f.tearDown() }
        let running = Workout(startedAt: f.clock.now, name: "Legs")
        try f.workouts.saveActive(running, pausedAt: nil)
        let deleted = try finished()
        try f.workouts.delete(deleted.id)
        let kept = watch(running.id)
        try f.store.applyRemote(workoutMeasurements: [kept, watch(deleted.id), watch(UUID())].map { pulled($0) })
        #expect(try measurements.snapshot(for: running.id) == kept)
        #expect(try f.context.fetchCount(FetchDescriptor<MeasurementRecord>()) == 1)
    }

    @Test func aRowAloneCountsAsLocalData() throws {
        defer { f.tearDown() }
        f.context.insert(MeasurementRecord(watch(UUID())))
        try f.context.save()
        #expect(try f.store.hasLocalData())
    }
}
