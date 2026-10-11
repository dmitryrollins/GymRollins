import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// `WorkoutRepository.recent` / `history` / `bests` with 150 imported-style workouts (4 exercises × 3 sets each) in an
/// on-disk store, like the app's. Target: < 50 ms each on the Mac (median of 10 runs after one warm-up).
///
/// Timing tests are noisy, so they only run with `GYM_PERF=1` (`scripts/test-perf.sh`), not in `swift test` /
/// `scripts/test-all.sh`. Baselines: docs/testing/performance.md.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GYM_PERF"] == "1", "set GYM_PERF=1 (scripts/test-perf.sh)"),
       .serialized)
struct WorkoutRepositoryPerformanceTests {
    static let workoutCount = 150
    static let budget: Duration = .milliseconds(50)
    static let runs = 10

    let container: ModelContainer
    let repo: WorkoutRepository
    let storeDir: URL

    init() throws {
        storeDir = FileManager.default.temporaryDirectory.appendingPathComponent("gymdata-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        container = try GymStore.container(inMemory: false, url: storeDir.appendingPathComponent("perf.store"))
        let now = Date(timeIntervalSince1970: 1_790_380_800)
        try OwnerSeed.applyLargeHistory(to: container.mainContext, now: now, count: Self.workoutCount)
        repo = WorkoutRepository(context: container.mainContext, now: { now })
    }

    /// Median wall time of `runs` calls after one warm-up call, printed as `PERF <name>: <ms> ms`.
    private func median(_ name: String, _ body: () throws -> Void) rethrows -> Duration {
        try body()
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<Self.runs {
            samples.append(try clock.measure(body))
        }
        let result = samples.sorted()[samples.count / 2]
        let ms = Double(result.components.attoseconds) / 1e15 + Double(result.components.seconds) * 1_000
        print("PERF \(name): \(String(format: "%.2f", ms)) ms (median of \(Self.runs), \(Self.workoutCount) workouts)")
        return result
    }

    @Test func recentIsFast() throws {
        #expect(try repo.recent(limit: 200).count == Self.workoutCount)
        #expect(try median("recent(limit: 50)") { _ = try repo.recent(limit: 50) } < Self.budget)
        #expect(try median("recent(limit: 200)") { _ = try repo.recent(limit: 200) } < Self.budget)
    }

    @Test func historyIsFast() throws {
        #expect(try repo.history(exerciseId: "0025", limit: 200).count == Self.workoutCount)
        #expect(try median("history(0025, limit: 1)") { _ = try repo.history(exerciseId: "0025", limit: 1) } < Self.budget)
        #expect(try median("history(0025, limit: 200)") { _ = try repo.history(exerciseId: "0025", limit: 200) }
            < Self.budget)
    }

    @Test func bestsAreFast() throws {
        #expect(try repo.bests(exerciseId: "0025") != nil)
        #expect(try median("bests(0025)") { _ = try repo.bests(exerciseId: "0025") } < Self.budget)
        #expect(try median("bests(0314)") { _ = try repo.bests(exerciseId: "0314") } < Self.budget)
    }
}
