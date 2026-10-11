import Foundation
import Testing
@testable import GymCore

/// Runs `fixtures/insights.json`, the cases the MCP server's TypeScript port (`_shared/insights.test.ts`) runs
/// too, so both sides compute the same numbers.
struct InsightsFixtureTests {
    struct Doc: Decodable {
        let exercises: [ExerciseRow]
        let cases: [Case]
    }

    struct ExerciseRow: Decodable {
        let id, n, bp, eq, tg: String
        let sm: [String]?
        let custom: Bool?
        let mode: String?

        var exercise: Exercise {
            Exercise(id: id, name: n, bodyPart: bp, equipment: eq, target: tg, secondary: sm ?? [],
                     isCustom: custom ?? false, mode: mode.flatMap(ExerciseMode.init(rawValue:)))
        }
    }

    struct Case: Decodable {
        let name, now, timeZone, limits: String
        let goal: Int
        let workouts: [WorkoutRow]
        let expected: Expected
        enum CodingKeys: String, CodingKey { case name, now, limits, goal, workouts, expected, timeZone = "time_zone" }
    }

    struct WorkoutRow: Decodable {
        let id, startedAt: String
        let endedAt: String?
        let entries: [EntryRow]
        enum CodingKeys: String, CodingKey {
            case id, startedAt = "started_at", endedAt = "ended_at", entries = "workout_entries"
        }
    }

    struct EntryRow: Decodable {
        let exerciseId: String
        let sets: [SetRow]
        enum CodingKeys: String, CodingKey { case exerciseId = "exercise_id", sets = "workout_sets" }
    }

    struct SetRow: Decodable {
        let weightKg: Double
        let r: Int
        let sec: Int?
        let done, warmup: Bool
        let rir, rpe: Double?
        enum CodingKeys: String, CodingKey { case r, sec, done, warmup, rir, rpe, weightKg = "w_kg" }
    }

    struct Expected: Decodable {
        let recovery: [String: Int]
        let weeklySets: [String: Double]
        let streak: StreakRow
        let fresh: [String]
        let limited: [String]
        enum CodingKeys: String, CodingKey { case recovery, streak, fresh, limited, weeklySets = "weekly_sets" }
    }

    struct StreakRow: Decodable {
        let current, longest, thisWeekDays: Int
        let thisWeekMet: Bool
        enum CodingKeys: String, CodingKey {
            case current, longest, thisWeekDays = "this_week_days", thisWeekMet = "this_week_met"
        }
    }

    static func load() throws -> Doc {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/insights.json")
        return try JSONDecoder().decode(Doc.self, from: Data(contentsOf: url))
    }

    static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    static func workout(_ w: WorkoutRow) -> Workout {
        Workout(id: UUID(uuidString: w.id)!, startedAt: date(w.startedAt), endedAt: w.endedAt.map(date), name: "W",
                entries: w.entries.map { e in
                    WorkoutEntry(exerciseId: e.exerciseId, sets: e.sets.map {
                        WorkoutSet(weightKg: $0.weightKg, reps: $0.r, sec: $0.sec, done: $0.done, warmup: $0.warmup,
                                   rir: $0.rir, rpe: $0.rpe)
                    })
                })
    }

    @Test func everyCaseMatches() throws {
        let doc = try Self.load()
        #expect(doc.cases.count >= 3)
        let library = Dictionary(uniqueKeysWithValues: doc.exercises.map { ($0.id, $0.exercise) })
        let lookup: (String) -> Exercise? = { library[$0] }
        for c in doc.cases {
            let now = Self.date(c.now)
            let calendar = TrainingWeek.calendar(timeZone: TimeZone(identifier: c.timeZone)!)
            let workouts = c.workouts.map(Self.workout)

            let recovery = RecoveryModel.compute(workouts: workouts, exercise: lookup, now: now)
            let percents = Dictionary(uniqueKeysWithValues: recovery.map { ($0.group.rawValue, $0.percent) })
            let expectedRecovery = Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.map {
                ($0.rawValue, c.expected.recovery[$0.rawValue] ?? 100)
            })
            #expect(percents == expectedRecovery, "\(c.name): recovery")

            let week = TrainingWeek.interval(containing: now, calendar: calendar)
            let sets = WeeklySets.count(workouts: workouts, exercise: lookup, week: week)
            #expect(Dictionary(uniqueKeysWithValues: sets.map { ($0.key.rawValue, $0.value) }) == c.expected.weeklySets,
                    "\(c.name): weekly sets")

            let streak = StreakCalculator.compute(workoutDates: workouts.map(\.startedAt), goal: c.goal, now: now,
                                                  calendar: calendar)
            #expect(streak.current == c.expected.streak.current, "\(c.name): current streak")
            #expect(streak.longest == c.expected.streak.longest, "\(c.name): longest streak")
            #expect(streak.thisWeekDays == c.expected.streak.thisWeekDays, "\(c.name): this week")
            #expect(streak.thisWeekMet == c.expected.streak.thisWeekMet, "\(c.name): this week met")

            let limited = LimitedMuscles.from(limits: c.limits)
            #expect(Set(limited.map(\.rawValue)) == Set(c.expected.limited), "\(c.name): limited")
            let fresh = RecoveryModel.freshest(recovery, limited: limited, now: now)
            #expect(fresh.map(\.rawValue) == c.expected.fresh, "\(c.name): fresh")
        }
    }
}
