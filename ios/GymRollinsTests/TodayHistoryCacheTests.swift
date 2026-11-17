import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Today's rows and the plan-mode exercise screen's suggestions share one read of each exercise's recent sessions,
/// kept until the workout data changes.
@MainActor
@Suite struct TodayHistoryCacheTests {
    private final class Reads {
        var ids: [String] = []
    }

    private func session(_ kg: Double) -> SessionResult {
        SessionResult(date: Date(timeIntervalSince1970: 1_790_000_000), weightKg: kg, reps: [8, 8, 8])
    }

    @Test func eachExerciseIsReadOnceUntilInvalidated() {
        let cache = TodayHistoryCache()
        let reads = Reads()
        let load: (String) throws -> [SessionResult] = { id in
            reads.ids.append(id)
            return [self.session(id == "0025" ? 100 : 50)]
        }
        #expect(cache.sessions("0025", load: load).map(\.weightKg) == [100])
        #expect(cache.sessions("0025", load: load).map(\.weightKg) == [100])
        #expect(cache.sessions("0070", load: load).map(\.weightKg) == [50])
        #expect(reads.ids == ["0025", "0070"])
        cache.invalidate()
        _ = cache.sessions("0025", load: load)
        #expect(reads.ids == ["0025", "0070", "0025"])
    }

    @Test func anEmptyHistoryIsKeptToo() {
        let cache = TodayHistoryCache()
        let reads = Reads()
        let load: (String) throws -> [SessionResult] = { reads.ids.append($0); return [] }
        #expect(cache.sessions("0025", load: load).isEmpty)
        #expect(cache.sessions("0025", load: load).isEmpty)
        #expect(reads.ids == ["0025"])
    }

    /// A failed read shows no history this time and is tried again next time.
    @Test func aFailedReadIsNotKept() {
        let cache = TodayHistoryCache()
        let reads = Reads()
        var fails = true
        let load: (String) throws -> [SessionResult] = { id in
            reads.ids.append(id)
            if fails { throw CocoaError(.fileReadUnknown) }
            return [self.session(80)]
        }
        #expect(cache.sessions("0025", load: load).isEmpty)
        fails = false
        #expect(cache.sessions("0025", load: load).map(\.weightKg) == [80])
        #expect(reads.ids == ["0025", "0025"])
    }

    /// The repository read Today uses: the last `limit` sessions.
    @Test func readsTheLastFiveSessionsFromTheStore() throws {
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow",
                                                                       "2026-09-26T09:00:00Z"]))
        for day in 0..<7 {
            let start = env.now().addingTimeInterval(Double(-(day + 1)) * 86_400)
            try env.workouts.save(Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: "Push",
                                          entries: [WorkoutEntry(exerciseId: "0025", sets: [
                                              WorkoutSet(weightKg: Double(60 + day), reps: 8, done: true)])]))
        }
        let cache = TodayHistoryCache()
        let sessions = cache.sessions("0025", in: env.workouts)
        #expect(sessions.count == TodayHistoryCache.limit)
        #expect(sessions == (try env.workouts.history(exerciseId: "0025", limit: 5)))
    }
}
