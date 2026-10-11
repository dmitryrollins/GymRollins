import Foundation
import SwiftData
import Testing
@testable import GymData

@MainActor
@Suite struct OwnerSeedTests {
    @Test func seedsSplitScheduleAndProfileOnce() throws {
        let container = try GymStore.container(inMemory: true)
        let context = container.mainContext
        try OwnerSeed.apply(to: context, now: Date(timeIntervalSince1970: 1_790_380_800))
        try OwnerSeed.apply(to: context, now: Date(timeIntervalSince1970: 1_790_380_800))
        let routines = try RoutineRepository(context: context).all()
        #expect(routines.map(\.name) == ["Push + Arms", "Pull + Shoulders + Triceps", "Upper weak points", "Legs"])
        #expect(routines[0].exercises.count == 7)
        #expect(routines[3].paused)
        #expect(try RoutineRepository(context: context).schedule().days[6] == routines[0].id)
        #expect(try ProfileRepository(context: context).load().goalWeightKg == 85)
    }

    @Test func applyHistorySeedsTwoBenchSessionsOnce() throws {
        let container = try GymStore.container(inMemory: true)
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_790_380_800)
        try OwnerSeed.applyHistory(to: context, now: now)
        try OwnerSeed.applyHistory(to: context, now: now)
        let workouts = WorkoutRepository(context: context, now: { now })
        #expect(try workouts.recent(limit: 10).count == 2)
        #expect(try workouts.history(exerciseId: "0025", limit: 5).first?.reps == [10, 10, 10])
    }

    @Test func applyPlankAddsOneTimedWorkoutOnceAlongsideHistory() throws {
        let container = try GymStore.container(inMemory: true)
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_790_380_800)
        try OwnerSeed.applyHistory(to: context, now: now)
        try OwnerSeed.applyPlank(to: context, now: now)
        try OwnerSeed.applyPlank(to: context, now: now)
        let workouts = WorkoutRepository(context: context, now: { now })
        let all = try workouts.recent(limit: 10)
        // applyHistory's 2 bench sessions untouched, plus exactly 1 plank workout.
        #expect(all.count == 3)
        let plank = try #require(all.first { $0.entries.contains { $0.exerciseId == "seed.plank" } })
        #expect(plank.entries.first?.sets.count == 3)
        #expect(plank.entries.first?.sets.allSatisfy { $0.sec == 30 } == true)
        // Seeded after applyHistory's dates, so it sorts first.
        #expect(all.first?.id == plank.id)
    }

    @Test func applyTemplateSeedsSplitWithoutTouchingProfileOrHistory() throws {
        let container = try GymStore.container(inMemory: true)
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_790_380_800)
        try ProfileRepository(context: context, now: { now }).save(Profile(heightCm: 170))
        try OwnerSeed.applyTemplate(to: context, now: now)
        try OwnerSeed.applyTemplate(to: context, now: now)
        let routines = try RoutineRepository(context: context).all()
        #expect(routines.map(\.name) == ["Push + Arms", "Pull + Shoulders + Triceps", "Upper weak points", "Legs"])
        #expect(try RoutineRepository(context: context).schedule().days[6] == routines[0].id)
        #expect(try ProfileRepository(context: context).load().heightCm == 170) // untouched, not overwritten
        #expect(try WorkoutRepository(context: context, now: { now }).recent(limit: 10).isEmpty)
    }

    @Test func applyLargeHistorySeeds60WorkoutsOnce() throws {
        let container = try GymStore.container(inMemory: true)
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_790_380_800)
        try OwnerSeed.applyLargeHistory(to: context, now: now)
        try OwnerSeed.applyLargeHistory(to: context, now: now)
        let workouts = WorkoutRepository(context: context, now: { now })
        let seeded = try workouts.recent(limit: 100)
        #expect(seeded.count == 60)
        #expect(seeded.allSatisfy { $0.entries.count == 4 && $0.entries.first?.exerciseId == "0025" })
    }

    @Test func applyLargeHistoryTakesACount() throws {
        let container = try GymStore.container(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_790_380_800)
        try OwnerSeed.applyLargeHistory(to: container.mainContext, now: now, count: 150)
        #expect(try WorkoutRepository(context: container.mainContext, now: { now }).recent(limit: 500).count == 150)
    }
}
