import Foundation
import GymCore
import Testing
@testable import GymRollins

/// Plan 39: the Log's history puts outside workouts between GymRollins workouts by start, newest first.
@Suite struct LogTimelineTests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-26T09:00:00Z")!

    private func workout(daysAgo: Double) -> Workout {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: "Push")
    }

    private func walk(daysAgo: Double) -> HealthActivity {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return HealthActivity(id: UUID(), kind: "walking", startedAt: start, endedAt: start.addingTimeInterval(1_800),
                              durationS: 1_800, sourceName: "Apple Watch", fromWatch: true)
    }

    @Test func outsideWorkoutsSitBetweenWorkoutsNewestFirst() {
        let w1 = workout(daysAgo: 1), w3 = workout(daysAgo: 3)
        let recent = walk(daysAgo: 0.5), between = walk(daysAgo: 2)
        let items = LogTimeline.merge(workouts: [w1, w3], outside: [recent, between], complete: true)
        #expect(items.map(\.id) == [recent.id, w1.id, between.id, w3.id])
    }

    @Test func olderOutsideWorkoutsWaitForTheNextPage() {
        let w1 = workout(daysAgo: 1), w3 = workout(daysAgo: 3)
        let between = walk(daysAgo: 2), older = walk(daysAgo: 5)
        let page = LogTimeline.merge(workouts: [w1, w3], outside: [between, older], complete: false)
        #expect(page.map(\.id) == [w1.id, between.id, w3.id])
        let all = LogTimeline.merge(workouts: [w1, w3], outside: [between, older], complete: true)
        #expect(all.last?.id == older.id)
    }

    @Test func withoutWorkoutsEveryOutsideWorkoutShows() {
        let a = walk(daysAgo: 1), b = walk(daysAgo: 4)
        #expect(LogTimeline.merge(workouts: [], outside: [a, b], complete: true).map(\.id) == [a.id, b.id])
    }
}
