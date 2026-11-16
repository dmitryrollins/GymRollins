import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// `history` and `sessions` read only the newest workouts they need, a page at a time. These check them against the
/// read they replace (every finished workout with the exercise, decoded and merged, then the first `limit` that give a
/// result) on data where that matters: sessions without a result, the exercise twice in one workout, deleted and
/// active workouts, workouts without it, and workouts that started at the same moment across a page boundary.
@MainActor
@Suite struct HistoryPagingTests {
    static let exercise = "0025"
    let container: ModelContainer
    let repo: WorkoutRepository
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        container = try GymStore.container(inMemory: true)
        let start = self.start
        repo = WorkoutRepository(context: container.mainContext, now: { start })
    }

    // MARK: The read being replaced

    private func everyFinishedEntry() throws -> [(date: Date, entry: WorkoutEntry)] {
        let exerciseId = Self.exercise
        let descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { workout in
                workout.deletedAt == nil && !workout.isActive && workout.entries.contains { $0.exerciseId == exerciseId }
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return try container.mainContext.fetch(descriptor).compactMap { workout in
            let entries = workout.entryValues.filter { $0.exerciseId == exerciseId }
            guard let first = entries.first else { return nil }
            let merged = entries.count == 1 ? first
                : WorkoutEntry(id: first.id, exerciseId: exerciseId, sets: entries.flatMap(\.sets), note: first.note,
                               supersetGroup: first.supersetGroup, gymListingId: first.gymListingId)
            return (date: workout.startedAt, entry: merged)
        }
    }

    private func expectedHistory(limit: Int) throws -> [SessionResult] {
        Array(try everyFinishedEntry().lazy.compactMap { SessionHistory.result(for: $0.entry, date: $0.date) }
            .prefix(limit))
    }

    private func expectSameAsBefore(_ limits: [Int] = [0, 1, 2, 4, 5, 6, 7, 10, 12, 50],
                                    sourceLocation: SourceLocation = #_sourceLocation) throws {
        for limit in limits {
            #expect(try repo.history(exerciseId: Self.exercise, limit: limit) == expectedHistory(limit: limit),
                    "history(limit: \(limit))", sourceLocation: sourceLocation)
            let sessions = try repo.sessions(exerciseId: Self.exercise, limit: limit)
            let expected = Array(try everyFinishedEntry().prefix(limit))
            #expect(sessions.map(\.date) == expected.map(\.date) && sessions.map(\.entry) == expected.map(\.entry),
                    "sessions(limit: \(limit))", sourceLocation: sourceLocation)
        }
    }

    // MARK: Data

    private func day(_ n: Int) -> Date { start.addingTimeInterval(Double(-n) * 86_400) }

    private func sets(_ kg: Double, done: Bool = true, warmup: Bool = false) -> [WorkoutSet] {
        (0..<3).map { _ in WorkoutSet(weightKg: kg, reps: 8, done: done, warmup: warmup) }
    }

    @discardableResult
    private func save(_ date: Date, _ entries: [WorkoutEntry]) throws -> Workout {
        let workout = Workout(startedAt: date, endedAt: date.addingTimeInterval(3_600), name: "W", entries: entries)
        try repo.save(workout)
        return workout
    }

    private func bench(_ kg: Double, done: Bool = true, warmup: Bool = false) -> WorkoutEntry {
        WorkoutEntry(exerciseId: Self.exercise, sets: sets(kg, done: done, warmup: warmup))
    }

    // MARK: Tests

    @Test func emptyHistory() throws {
        try expectSameAsBefore()
        #expect(try repo.history(exerciseId: Self.exercise, limit: 5).isEmpty)
    }

    /// Sessions without a done working set give no result; the next older ones fill the five, across pages.
    @Test func sessionsWithoutAResultAreSkippedAcrossPages() throws {
        for n in 0..<30 {
            switch n % 4 {
            case 0: try save(day(n), [bench(Double(60 + n))])
            case 1: try save(day(n), [bench(Double(60 + n), done: false)]) // logged, never done
            case 2: try save(day(n), [bench(20, warmup: true)]) // warm-ups only
            default: try save(day(n), [WorkoutEntry(exerciseId: "0070", sets: sets(30))]) // no bench
            }
        }
        // The six newest with the bench hold only two results.
        try expectSameAsBefore()
        #expect(try repo.history(exerciseId: Self.exercise, limit: 5).map(\.weightKg) == [60, 64, 68, 72, 76])
    }

    /// Many in a row without a result, more than a page of them.
    @Test func aLongRunWithoutResults() throws {
        try save(day(40), [bench(80)])
        for n in 0..<17 { try save(day(n), [bench(50, done: false)]) }
        try expectSameAsBefore()
        #expect(try repo.history(exerciseId: Self.exercise, limit: 5).map(\.weightKg) == [80])
    }

    @Test func theExerciseTwiceInOneWorkoutIsOneSession() throws {
        for n in 0..<8 {
            try save(day(n), [bench(Double(70 + n)), WorkoutEntry(exerciseId: "0070", sets: sets(30)),
                              bench(Double(70 + n), done: n % 2 == 0)])
        }
        try expectSameAsBefore()
        #expect(try repo.sessions(exerciseId: Self.exercise, limit: 3).map(\.entry.sets.count) == [6, 6, 6])
    }

    @Test func deletedAndActiveWorkoutsAreLeftOut() throws {
        for n in 0..<12 {
            let workout = try save(day(n), [bench(Double(90 + n))])
            if n % 3 == 0 { try repo.delete(workout.id) }
        }
        try repo.saveActive(Workout(startedAt: start.addingTimeInterval(600), name: "Live", entries: [bench(200)]),
                            pausedAt: nil)
        try expectSameAsBefore()
        #expect(try repo.history(exerciseId: Self.exercise, limit: 5).map(\.weightKg) == [91, 92, 94, 95, 97])
    }

    /// Workouts that started at the same moment (an import with dates only) are each read once, even when they fall on
    /// both sides of a page.
    @Test func workoutsStartingAtTheSameMomentAreEachReadOnce() throws {
        for n in 0..<4 { try save(day(1), [bench(Double(100 + n))]) }
        for n in 0..<4 { try save(day(2), [bench(Double(110 + n), done: n != 1)]) }
        try save(day(3), [bench(120)])
        for limit in 1...10 {
            let history = try repo.history(exerciseId: Self.exercise, limit: limit)
            let expected = try expectedHistory(limit: limit)
            #expect(history.count == expected.count, "limit \(limit)")
            #expect(history.map(\.date) == expected.map(\.date), "limit \(limit): newest first")
            #expect(Set(history.map(\.weightKg)).count == history.count, "limit \(limit): a workout read twice")
            let sessions = try repo.sessions(exerciseId: Self.exercise, limit: limit)
            #expect(Set(sessions.map(\.entry.id)).count == sessions.count, "limit \(limit): a session read twice")
        }
        #expect(Set(try repo.history(exerciseId: Self.exercise, limit: 10).map(\.weightKg))
                == [100, 101, 102, 103, 110, 112, 113, 120])
    }

    @Test func bestsStillReadEverySession() throws {
        try save(day(30), [bench(150)])
        for n in 0..<10 { try save(day(n), [bench(100)]) }
        #expect(try repo.bests(exerciseId: Self.exercise)?.e1RMKg == ExerciseBests(entry: bench(150)).e1RMKg)
    }
}
