import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Plan 40: what Apple Health measured during a GymRollins workout, one snapshot per workout, written only when the
/// numbers changed and only for a finished workout that is still here.
@MainActor
@Suite struct MeasurementRepositoryTests {
    let container: ModelContainer
    let clock = TestClock()

    init() throws { container = try GymStore.container(inMemory: true) }

    private var repo: MeasurementRepository { MeasurementRepository(context: container.mainContext) }
    private var workouts: WorkoutRepository {
        WorkoutRepository(context: container.mainContext, now: { [clock] in clock.now })
    }

    /// A finished "Push + Biceps" of 58 min 20 s, as `-seedHistory` has them.
    @discardableResult
    private func finished(daysAgo: Double = 7) throws -> Workout {
        let start = clock.now.addingTimeInterval(-daysAgo * 86_400)
        let workout = Workout(startedAt: start, endedAt: start.addingTimeInterval(3_500), name: "Push + Biceps")
        try workouts.save(workout)
        return workout
    }

    /// What the Apple Watch recorded for it.
    private func watch(_ workoutId: UUID, activeKcal: Double = 412, effort: Int? = 6,
                       at date: Date? = nil) -> MeasurementSnapshot {
        MeasurementSnapshot(workoutId: workoutId, recordedBy: .watch, durationS: 3_500, activeKcal: activeKcal,
                            totalKcal: 489, avgHr: 128, maxHr: 162, postHr: 124, effort: effort,
                            effortEstimated: false, clientUpdatedAt: date ?? clock.now)
    }

    @Test func aWorkoutsNumbersAreSavedAndReadBackAndAReReadChangesNothing() throws {
        let workout = try finished()
        let numbers = watch(workout.id)
        #expect(try repo.snapshot(for: workout.id) == nil)
        #expect(try repo.save(numbers))
        #expect(try repo.snapshot(for: workout.id) == numbers)

        clock.advance()
        #expect(try !repo.save(watch(workout.id)), "the same numbers, read again later")
        #expect(try repo.snapshot(for: workout.id)?.clientUpdatedAt == numbers.clientUpdatedAt)
    }

    @Test func newNumbersReplaceTheOldAndTheEditTimeNeverGoesBack() throws {
        let workout = try finished()
        try repo.save(watch(workout.id))
        let rated = watch(workout.id, effort: 8) // the same clock: an edit time no later than the stored one
        #expect(try repo.save(rated))
        let stored = try #require(try repo.snapshot(for: workout.id))
        #expect(stored.effort == 8)
        #expect(stored.clientUpdatedAt > rated.clientUpdatedAt)

        let effortOnly = MeasurementSnapshot(workoutId: workout.id, recordedBy: nil, durationS: nil, activeKcal: nil,
                                             totalKcal: nil, avgHr: nil, maxHr: nil, postHr: nil, effort: 5,
                                             effortEstimated: true, clientUpdatedAt: clock.now.addingTimeInterval(60))
        #expect(try repo.save(effortOnly))
        #expect(try repo.snapshot(for: workout.id) == effortOnly)
    }

    @Test func numbersOutsideTheLimitsAreRefused() throws {
        let workout = try finished()
        #expect(throws: GymDataError.self) { try repo.save(watch(workout.id, activeKcal: 20_001)) }
        #expect(throws: GymDataError.self) { try repo.save(watch(workout.id, effort: 11)) }
        #expect(try repo.snapshot(for: workout.id) == nil)
    }

    @Test func onlyAFinishedWorkoutThatIsStillHereKeepsNumbers() throws {
        #expect(try !repo.save(watch(UUID())), "not on this iPhone")
        let deleted = try finished()
        try workouts.delete(deleted.id)
        #expect(try !repo.save(watch(deleted.id)), "deleted while Health was read")
        let running = Workout(startedAt: clock.now, name: "Legs")
        try workouts.saveActive(running, pausedAt: nil)
        #expect(try !repo.save(watch(running.id)), "still running")
        #expect(try container.mainContext.fetchCount(FetchDescriptor<MeasurementRecord>()) == 0)
    }

    @Test func theNumbersGoWithTheirWorkout() throws {
        let workout = try finished()
        let kept = try finished(daysAgo: 1)
        try repo.save(watch(workout.id))
        try repo.save(watch(kept.id))
        try workouts.delete(workout.id)
        #expect(try repo.snapshot(for: workout.id) == nil)
        #expect(try repo.snapshot(for: kept.id) != nil)
    }

    @Test func theBackfillListsFinishedWorkoutsFromADateNewestFirst() throws {
        let tooOld = try finished(daysAgo: 100)
        let older = try finished(daysAgo: 30)
        let recent = try finished(daysAgo: 2)
        let gone = try finished(daysAgo: 5)
        try workouts.delete(gone.id)
        try workouts.saveActive(Workout(startedAt: clock.now, name: "Legs"), pausedAt: nil)
        let ids = try repo.finishedWorkoutIds(since: clock.now.addingTimeInterval(-90 * 86_400))
        #expect(ids == [recent.id, older.id])
        #expect(!ids.contains(tooOld.id))
    }

    /// A phone holds a store from plan 39's build. The new model is a new table, which SwiftData adds by
    /// lightweight migration, as for every model since plan 15: there is no `VersionedSchema`.
    @Test func aStoreFromBeforePlan40OpensWithTheNewModel() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gymdata-plan40-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("before.store")
        let start = clock.now.addingTimeInterval(-86_400)
        let workout = Workout(startedAt: start, endedAt: start.addingTimeInterval(3_500), name: "Push + Biceps")
        do {
            let before = GymStore.models.filter { ObjectIdentifier($0) != ObjectIdentifier(MeasurementRecord.self) }
            let old = try ModelContainer(for: Schema(before), configurations: ModelConfiguration(url: url))
            try WorkoutRepository(context: old.mainContext, now: { [clock] in clock.now }).save(workout)
        }
        do {
            let new = try GymStore.container(inMemory: false, url: url)
            #expect(try WorkoutRepository(context: new.mainContext).workout(workout.id)?.name == "Push + Biceps")
            #expect(try MeasurementRepository(context: new.mainContext).save(watch(workout.id)))
        }
        try FileManager.default.removeItem(at: dir)
    }
}
