import Foundation
import Testing
@testable import GymCore

/// Runs `fixtures/strength-levels.json`, the cases the MCP server's TypeScript port (`_shared/strength-levels.test.ts`)
/// runs too, on the bundled table, so both sides compute the same levels.
struct StrengthFixtureTests {
    struct Doc: Decodable { let cases: [Case] }

    struct Case: Decodable {
        let name, limits, now: String
        let sex: String?
        let birthYear: Int?
        let bodyweightKg: Double?
        let workouts: [WorkoutRow]
        let expected: Expected
        enum CodingKeys: String, CodingKey {
            case name, limits, now, sex, workouts, expected, birthYear = "birth_year", bodyweightKg = "bodyweight_kg"
        }
    }

    struct WorkoutRow: Decodable {
        let startedAt: String
        let entries: [EntryRow]
        enum CodingKeys: String, CodingKey { case startedAt = "started_at", entries = "workout_entries" }
    }

    struct EntryRow: Decodable {
        let exerciseId: String
        let sets: [SetRow]
        enum CodingKeys: String, CodingKey { case exerciseId = "exercise_id", sets = "workout_sets" }
    }

    struct SetRow: Decodable {
        let wKg: Double
        let r: Int
        let done, warmup: Bool
        enum CodingKeys: String, CodingKey { case r, done, warmup, wKg = "w_kg" }
    }

    struct Expected: Decodable {
        let missing: [String]
        let age: Int?
        let lifts: [String: LiftExpected]
    }

    struct LiftExpected: Decodable {
        let e1rmKg: Double?
        let exerciseId: String?
        let level: String?
        let percentile: Double?
        let next: String?
        let nextTargetKg: Double?
        let paused: Bool
        enum CodingKeys: String, CodingKey {
            case level, percentile, next, paused, e1rmKg = "e1rm_kg", exerciseId = "exercise_id"
            case nextTargetKg = "next_target_kg"
        }
    }

    static func cases() throws -> [Case] {
        let url = StrengthFixture.repoRoot.appendingPathComponent("fixtures/strength-levels.json")
        return try JSONDecoder().decode(Doc.self, from: Data(contentsOf: url)).cases
    }

    private func near(_ actual: Double?, _ expected: Double?, _ comment: Comment) {
        guard let expected else { return #expect(actual == nil, comment) }
        #expect(actual.map { abs($0 - expected) <= 0.01 } == true, "\(comment): \(String(describing: actual))")
    }

    @Test func everyFixtureCaseMatches() throws {
        let standards = try StrengthFixture.bundled()
        let cases = try Self.cases()
        #expect(cases.count >= 7)
        for c in cases {
            let workouts = c.workouts.map { w in
                Workout(startedAt: StrengthFixture.date(w.startedAt), name: "W", entries: w.entries.map { e in
                    WorkoutEntry(exerciseId: e.exerciseId, sets: e.sets.map {
                        WorkoutSet(weightKg: $0.wKg, reps: $0.r, done: $0.done, warmup: $0.warmup)
                    })
                })
            }
            let report = StrengthReport.make(
                standards: standards, workouts: workouts, sex: c.sex.flatMap(ProfileSex.init(rawValue:)),
                birthYear: c.birthYear, bodyweightKg: c.bodyweightKg, limits: c.limits,
                now: StrengthFixture.date(c.now), calendar: StrengthFixture.utc())
            #expect(report.missing.map(\.rawValue) == c.expected.missing, "\(c.name)")
            #expect(report.age == c.expected.age, "\(c.name)")
            for row in report.rows {
                let e = try #require(c.expected.lifts[row.lift.rawValue])
                let comment: Comment = "\(c.name) / \(row.lift.rawValue)"
                near(row.estimate?.e1RMKg, e.e1rmKg, comment)
                #expect(row.estimate?.exerciseId == e.exerciseId, comment)
                #expect(row.assessment?.level.rawValue == e.level, comment)
                near(row.assessment?.percentile, e.percentile, comment)
                #expect(row.assessment?.next?.rawValue == e.next, comment)
                near(row.assessment?.nextTargetKg, e.nextTargetKg, comment)
                #expect(row.paused == e.paused, comment)
            }
        }
    }
}
