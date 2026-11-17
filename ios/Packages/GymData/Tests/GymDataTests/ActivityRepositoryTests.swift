import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Plan 39: outside workouts and days of activity on this iPhone. Only the Health import writes them.
@MainActor
@Suite struct ActivityRepositoryTests {
    let container: ModelContainer
    let clock = TestClock()

    init() throws { container = try GymStore.container(inMemory: true) }

    private var repo: ActivityRepository {
        ActivityRepository(context: container.mainContext, now: { [clock] in clock.now })
    }
    private var workouts: WorkoutRepository {
        WorkoutRepository(context: container.mainContext, now: { [clock] in clock.now })
    }

    private func walk(id: UUID = UUID(), daysAgo: Double, minutes: Double = 45) -> HealthActivity {
        let start = clock.now.addingTimeInterval(-daysAgo * 86_400)
        return HealthActivity(id: id, kind: "walking", startedAt: start,
                              endedAt: start.addingTimeInterval(minutes * 60), durationS: minutes * 60, kcal: 180,
                              distanceM: 3_400, avgHr: 102, maxHr: 121, sourceName: "Apple Watch", fromWatch: true)
    }

    @Test func anOutsideWorkoutIsAddedOnceAndATombstoneNeverComesBack() throws {
        let walk = walk(daysAgo: 1)
        #expect(try repo.add(walk, editedAt: walk.endedAt))
        #expect(try !repo.add(walk, editedAt: clock.now), "already here")
        #expect(try repo.activity(walk.id) == walk)

        clock.advance()
        #expect(try repo.delete(walk.id))
        #expect(try repo.activity(walk.id) == nil)
        #expect(try repo.hasRecord(id: walk.id))
        #expect(try !repo.delete(walk.id), "already deleted")
        #expect(try !repo.add(walk, editedAt: clock.now), "a tombstone never comes back")
        #expect(try !repo.delete(UUID()), "nothing to delete")
    }

    @Test func activitiesAreLiveNewestFirstAndFromADate() throws {
        let old = walk(daysAgo: 10), recent = walk(daysAgo: 1), gone = walk(daysAgo: 2)
        for activity in [old, recent, gone] { try repo.add(activity, editedAt: activity.endedAt) }
        try repo.delete(gone.id)
        #expect(try repo.activities(since: nil) == [recent, old])
        #expect(try repo.activities(since: clock.now.addingTimeInterval(-3 * 86_400)) == [recent])
    }

    @Test func oneOutsideTheLimitsIsRefused() throws {
        let start = clock.now
        let tooLong = HealthActivity(id: UUID(), kind: "walking", startedAt: start,
                                     endedAt: start.addingTimeInterval(60), durationS: 90_000,
                                     sourceName: "Apple Watch")
        #expect(throws: GymDataError.self) { try repo.add(tooLong, editedAt: start) }
        #expect(try repo.activities(since: nil).isEmpty)
    }

    @Test func aDayIsWrittenOnlyWhenNewOrChanged() throws {
        let day = ActivityDay(day: "2026-09-21", steps: 8_532, moveKcal: 410, exerciseMin: 34, standH: 11)
        #expect(try repo.save(day: day))
        #expect(try !repo.save(day: day), "unchanged")
        let later = ActivityDay(day: "2026-09-21", steps: 9_001, moveKcal: 430, exerciseMin: 36, standH: 12)
        #expect(try repo.save(day: later))
        #expect(try repo.days(from: "2026-09-21", through: "2026-09-21") == [later])
        let tooMany = ActivityDay(day: "2026-09-22", steps: 200_001, moveKcal: 0, exerciseMin: 0, standH: nil)
        #expect(throws: GymDataError.self) { try repo.save(day: tooMany) }
    }

    @Test func daysComeOldestFirstWithinTheRange() throws {
        for key in ["2026-09-22", "2026-09-20", "2026-09-21", "2026-09-28"] {
            try repo.save(day: ActivityDay(day: key, steps: 1_000, moveKcal: 100, exerciseMin: 10, standH: nil))
        }
        #expect(try repo.days(from: "2026-09-20", through: "2026-09-22").map(\.day)
            == ["2026-09-20", "2026-09-21", "2026-09-22"])
    }

    @Test func finishedSpansSkipTheRunningAndTheDeleted() throws {
        let start = clock.now.addingTimeInterval(-86_400)
        let kept = Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: "Push")
        let deleted = Workout(startedAt: start.addingTimeInterval(-86_400),
                              endedAt: start.addingTimeInterval(-82_800), name: "Pull")
        try workouts.save(kept)
        try workouts.save(deleted)
        try workouts.delete(deleted.id)
        try workouts.saveActive(Workout(startedAt: clock.now, name: "Legs"), pausedAt: nil)
        #expect(try workouts.finishedSpans(since: nil)
            == [WorkoutSpan(id: kept.id, start: start, end: start.addingTimeInterval(3_600))])
        #expect(try workouts.finishedSpans(since: clock.now).isEmpty)
        #expect(try workouts.finishedCount() == 1, "not the running or the deleted one")
    }

    @Test func theLiveCountLeavesOutTombstones() throws {
        #expect(try repo.liveCount() == 0)
        let first = walk(daysAgo: 1), second = walk(daysAgo: 2)
        try repo.add(first, editedAt: clock.now)
        try repo.add(second, editedAt: clock.now)
        #expect(try repo.liveCount() == 2)
        try repo.delete(first.id)
        #expect(try repo.liveCount() == 1)
    }
}
