import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Timing for Today's "last 5 sessions" read with an owner-sized history: 160 workouts of 6 exercises × 3 sets (2,880
/// sets), the staple lift in 100 of them, in an on-disk store like the app's. Prints `PERF …` lines and asserts nothing
/// about time (Today calls `history(limit: 5)` once per plan item on every reload).
///
/// Only runs with `GYM_PERF=1` (`scripts/test-perf.sh data`), like `WorkoutRepositoryPerformanceTests`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GYM_PERF"] == "1", "set GYM_PERF=1 (scripts/test-perf.sh)"),
       .serialized)
struct HistoryTimingTests {
    static let workoutCount = 160
    static let staple = "0025"
    static let runs = 20

    let container: ModelContainer
    let repo: WorkoutRepository

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gymdata-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        container = try GymStore.container(inMemory: false, url: dir.appendingPathComponent("history.store"))
        let now = Date(timeIntervalSince1970: 1_790_380_800)
        repo = WorkoutRepository(context: container.mainContext, now: { now })
        let others = ["0070", "0314", "0334", "0652", "1460", "0043", "0032", "0188", "0294"]
        for day in 0..<Self.workoutCount {
            let start = now.addingTimeInterval(Double(-(day + 1)) * 86_400)
            // The staple in 5 workouts out of 8 (100 of 160), otherwise a sixth accessory.
            let ids = (day % 8 < 5 ? [Self.staple] : [others[day % others.count]])
                + (0..<5).map { others[(day + $0) % others.count] }
            let entries = ids.enumerated().map { index, id in
                WorkoutEntry(exerciseId: id, sets: (0..<3).map { set in
                    WorkoutSet(weightKg: Double(100 - index * 10 + day % 5), reps: 8 + set % 2, done: true,
                               completedAt: start.addingTimeInterval(Double(index * 3 + set) * 150))
                })
            }
            try repo.save(Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: "Day \(day)",
                                  entries: entries))
        }
    }

    /// Median wall time of `runs` calls after one warm-up, printed as `PERF <name>: <ms> ms`.
    private func median(_ name: String, _ body: () throws -> Void) rethrows {
        try body()
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<Self.runs { samples.append(try clock.measure(body)) }
        let result = samples.sorted()[samples.count / 2]
        let ms = Double(result.components.attoseconds) / 1e15 + Double(result.components.seconds) * 1_000
        print("PERF \(name): \(String(format: "%.2f", ms)) ms (median of \(Self.runs))")
    }

    @Test func historyOfTheStapleLift() throws {
        #expect(try repo.history(exerciseId: Self.staple, limit: 200).count == 100)
        try median("history(staple in 100 of 160, limit: 5)") { _ = try repo.history(exerciseId: Self.staple, limit: 5) }
        try median("history(accessory, limit: 5)") { _ = try repo.history(exerciseId: "0070", limit: 5) }
        try median("history(staple, limit: 200)") { _ = try repo.history(exerciseId: Self.staple, limit: 200) }
        try median("6 plan items × history(limit: 5)") {
            for id in [Self.staple, "0070", "0314", "0334", "0652", "1460"] { _ = try repo.history(exerciseId: id, limit: 5) }
        }
    }
}
