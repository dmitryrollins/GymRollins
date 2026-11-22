import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymSync

/// Plan 40: what Apple Health measured during a workout, on the wire and through a sync round, after the workouts.
@MainActor
@Suite struct MeasurementSyncTests {
    let f: EngineFixture
    init() throws { f = try EngineFixture() }

    private var measurements: MeasurementRepository { MeasurementRepository(context: f.container.mainContext) }

    private func watch(_ workoutId: UUID, effort: Int? = 6, at date: Date? = nil) -> MeasurementSnapshot {
        MeasurementSnapshot(workoutId: workoutId, recordedBy: .watch, durationS: 3_500, activeKcal: 412,
                            totalKcal: 489, avgHr: 128, maxHr: 162, postHr: 124, effort: effort,
                            effortEstimated: false, clientUpdatedAt: date ?? f.clock.now)
    }

    @Test func theNumbersTravelSnakeCasedWithExplicitNulls() throws {
        defer { f.tearDown() }
        let effortOnly = MeasurementSnapshot(workoutId: UUID(), recordedBy: nil, durationS: nil, activeKcal: nil,
                                             totalKcal: nil, avgHr: nil, maxHr: nil, postHr: nil, effort: 5,
                                             effortEstimated: true, clientUpdatedAt: t0)
        let row = SyncRow(value: effortOnly, clientUpdatedAt: t0)
        let body = String(decoding: try SyncJSON.encoder.encode(WorkoutMeasurementDTO(row)), as: UTF8.self)
        for key in [#""recorded_by":null"#, #""active_kcal":null"#, #""effort":5"#, #""effort_estimated":true"#,
                    #""deleted_at":null"#, #""workout_id":""#] {
            #expect(body.contains(key), "\(key) in \(body)")
        }
        #expect(!body.contains(#""updated_at""#), "updated_at is the server's")
        #expect(try wire(WorkoutMeasurementDTO(row)).toDomain().value == effortOnly)

        let recording = MeasurementSnapshot(workoutId: UUID(), recordedBy: .appleWorkout, durationS: 3_000,
                                            activeKcal: 380, totalKcal: nil, avgHr: 131, maxHr: 158, postHr: nil,
                                            effort: nil, effortEstimated: false, clientUpdatedAt: t0)
        let attached = SyncRow(value: recording, clientUpdatedAt: t0)
        let wired = String(decoding: try SyncJSON.encoder.encode(WorkoutMeasurementDTO(attached)), as: UTF8.self)
        #expect(wired.contains(#""recorded_by":"apple_workout""#))
        #expect(try wire(WorkoutMeasurementDTO(attached)).toDomain().value == attached.value)
    }

    @Test func aNewWorkoutAndItsNumbersGoUpInOneRoundWorkoutFirst() async throws {
        defer { f.tearDown() }
        let w = workout(name: "Push + Biceps", at: f.clock.now.addingTimeInterval(-3_600))
        try f.workouts.save(w)
        try measurements.save(watch(w.id))

        await f.engine.sync()

        #expect(await f.server.workouts[w.id] != nil)
        #expect(await f.server.workoutMeasurements[w.id]?.activeKcal == 412)
        #expect(try f.store.dirtyWorkoutMeasurements().isEmpty)
        #expect(f.store.syncFailures().isEmpty, "the server held the workout when its numbers came")
    }

    @Test func theNumbersOfAWorkoutTheServerRefusedWaitAndTheRestSync() async throws {
        defer { f.tearDown() }
        let refused = workout(name: "Push", at: f.clock.now.addingTimeInterval(-7_200))
        let fine = workout(name: "Pull", at: f.clock.now.addingTimeInterval(-3_600))
        try f.workouts.save(refused)
        try f.workouts.save(fine)
        try measurements.save(watch(refused.id))
        try measurements.save(watch(fine.id))
        await f.server.reject(ids: [refused.id.uuidString])

        await f.engine.sync()

        #expect(await f.server.workoutMeasurements[fine.id] != nil)
        #expect(await f.server.workoutMeasurements[refused.id] == nil)
        #expect(f.store.syncFailures().map(\.entity) == [.workouts], "its numbers wait instead of being refused too")
        #expect(try f.store.dirtyWorkoutMeasurements().map(\.value.workoutId) == [refused.id])
    }

    @Test func numbersWhoseWorkoutTheServerRefusedAreNotSentOrBlocked() async throws {
        defer { f.tearDown() }
        let w = workout(name: "Push", at: f.clock.now.addingTimeInterval(-3_600))
        try f.workouts.save(w)
        try measurements.save(watch(w.id))
        await f.server.reject(ids: [w.id.uuidString])

        await f.engine.sync()

        #expect(await f.server.workoutMeasurements[w.id] == nil)
        #expect(!f.store.syncFailures().contains { $0.entity == .workoutMeasurements }, "waiting, not refused")
        #expect(try f.store.dirtyWorkoutMeasurements().count == 1)
    }

    @Test func anotherDevicesNumbersComeDownAfterTheirWorkout() async throws {
        defer { f.tearDown() }
        let w = workout(name: "Push + Biceps", at: f.clock.now.addingTimeInterval(-3_600))
        let snapshot = WorkoutSnapshot(workout: w, records: [], volumeKg: 0)
        try await f.server.seed(workout: WorkoutDTO(SyncRow(value: snapshot, clientUpdatedAt: f.clock.now)))
        let numbers = watch(w.id)
        try await f.server.seed(workoutMeasurement: WorkoutMeasurementDTO(SyncRow(value: numbers,
                                                                                  clientUpdatedAt: f.clock.now)))

        await f.engine.sync()

        #expect(try f.workouts.workout(w.id) != nil)
        #expect(try measurements.snapshot(for: w.id) == numbers)
        #expect(f.store.cursor(for: .workoutMeasurements) != nil)
    }

    @Test func numbersOfAWorkoutDeletedHereStayAway() async throws {
        defer { f.tearDown() }
        let w = workout(name: "Push + Biceps", at: f.clock.now.addingTimeInterval(-3_600))
        try f.workouts.save(w)
        try measurements.save(watch(w.id))
        await f.engine.sync()
        f.clock.advance()
        try f.workouts.delete(w.id)
        #expect(try measurements.snapshot(for: w.id) == nil)
        try await f.server.seed(workoutMeasurement: WorkoutMeasurementDTO(SyncRow(value: watch(w.id, effort: 8),
                                                                                  clientUpdatedAt: f.clock.now)))

        await f.engine.sync()

        #expect(try measurements.snapshot(for: w.id) == nil, "another phone's late numbers for it are skipped")
        #expect(await f.server.workouts[w.id]?.deletedAt != nil)
    }
}
