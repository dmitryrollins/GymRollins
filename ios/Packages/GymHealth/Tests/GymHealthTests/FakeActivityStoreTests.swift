import Foundation
import GymCore
import Testing
@testable import GymHealth

/// Plan 39: the fake Health reads outside workouts like HealthKit's anchored query (deletions only after an anchor)
/// and days by calendar day.
@Suite struct FakeActivityStoreTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func walk(daysAgo: Double) -> HealthOutsideWorkout {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return HealthOutsideWorkout(activity: HealthActivity(
            id: UUID(), kind: "walking", startedAt: start, endedAt: start.addingTimeInterval(1_800), durationS: 1_800,
            sourceName: "Apple Watch", fromWatch: true))
    }

    @Test func outsideWorkoutsComeAnchoredWithTheirDeletions() async throws {
        let old = walk(daysAgo: 800), recent = walk(daysAgo: 3)
        let store = FakeHealthStore(outsideWorkouts: [old, recent])
        let first = try await store.outsideWorkoutChanges(since: now.addingTimeInterval(-730 * 86_400), anchor: nil)
        #expect(first.added == [recent])
        #expect(first.deleted.isEmpty)

        let later = walk(daysAgo: 1)
        await store.addOutsideWorkout(later)
        await store.deleteOutsideWorkout(recent.activity.id)
        let next = try await store.outsideWorkoutChanges(since: .distantPast, anchor: first.anchor)
        #expect(next.added == [later])
        #expect(next.deleted == [recent.activity.id])
    }

    @Test func daysComeByCalendarDayOldestFirst() async throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let days = FakeHealthStore.uiTestActivityDays(now: now, calendar: utc)
        #expect(days.count == 7)
        let store = FakeHealthStore(days: days)
        let read = try await store.activityDays(from: now.addingTimeInterval(-86_400), through: now, calendar: utc)
        #expect(read.map(\.steps) == [8_532, 4_210])
        #expect(await store.dayReads.count == 1)
    }

    @Test func theUITestSeedAttachesItsStrengthRecordingToSeedHistorysWorkout() throws {
        let fixedNow = try #require(ISO8601DateFormatter().date(from: "2026-09-26T09:00:00Z"))
        let seeded = FakeHealthStore.uiTestOutsideWorkouts(now: fixedNow).map(\.activity)
        let history = try #require(ISO8601DateFormatter().date(from: "2026-09-19T18:00:00Z")) // OwnerSeed.applyHistory
        let workout = WorkoutSpan(id: UUID(), start: history, end: history.addingTimeInterval(3_500))
        let resolved = ActivityRules.resolve(seeded, workouts: [workout])
        #expect(resolved.shown.map(\.id) == [FakeHealthStore.uiTestWalkId])
        #expect(resolved.measured(for: workout.id)?.id == FakeHealthStore.uiTestStrengthId)
    }
}
