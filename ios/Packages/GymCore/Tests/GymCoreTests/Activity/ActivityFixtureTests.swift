import Foundation
import Testing
@testable import GymCore

/// Runs `fixtures/activity.json`, the cases the server's TypeScript mirror (`server/test/shared/activity.test.ts`) runs
/// too: rules 6 and 7, what counts, and the streak with outside workouts in it (plan 39).
struct ActivityFixtureTests {
    struct Doc: Decodable {
        let cases: [Case]
    }

    struct Case: Decodable {
        let name, now, timeZone: String
        let goal: Int
        let workouts: [WorkoutRow]
        let activities: [ActivityRow]
        let expected: Expected
        enum CodingKeys: String, CodingKey {
            case name, now, goal, workouts, activities, expected, timeZone = "time_zone"
        }
    }

    struct WorkoutRow: Decodable {
        let id, startedAt, endedAt: String
        enum CodingKeys: String, CodingKey { case id, startedAt = "started_at", endedAt = "ended_at" }
    }

    struct ActivityRow: Decodable {
        let id, kind, startedAt, endedAt: String
        let durationS: Double
        let fromWatch: Bool
        enum CodingKeys: String, CodingKey {
            case id, kind, startedAt = "started_at", endedAt = "ended_at", durationS = "duration_s"
            case fromWatch = "from_watch"
        }
    }

    struct Expected: Decodable {
        let shown: [String]
        let attached: [String: String]
        let counted: [String]
        let streak: StreakRow
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
            .deletingLastPathComponent().appendingPathComponent("fixtures/activity.json")
        return try JSONDecoder().decode(Doc.self, from: Data(contentsOf: url))
    }

    static func date(_ iso: String) throws -> Date { try #require(ISO8601DateFormatter().date(from: iso)) }

    static func uuid(_ text: String) throws -> UUID { try #require(UUID(uuidString: text)) }

    @Test func everyCaseMatches() throws {
        let doc = try Self.load()
        #expect(doc.cases.count >= 6)
        for c in doc.cases {
            let workouts = try c.workouts.map {
                WorkoutSpan(id: try Self.uuid($0.id), start: try Self.date($0.startedAt),
                            end: try Self.date($0.endedAt))
            }
            let activities = try c.activities.map {
                HealthActivity(id: try Self.uuid($0.id), kind: $0.kind, startedAt: try Self.date($0.startedAt),
                               endedAt: try Self.date($0.endedAt), durationS: $0.durationS, sourceName: "Fixture",
                               fromWatch: $0.fromWatch)
            }
            let resolved = ActivityRules.resolve(activities, workouts: workouts)
            let ids = { (list: [HealthActivity]) in list.map { $0.id.uuidString.lowercased() } }
            #expect(ids(resolved.shown) == c.expected.shown, "\(c.name): shown")
            let attached = Dictionary(uniqueKeysWithValues: resolved.attachedTo.map {
                ($0.key.uuidString.lowercased(), $0.value.uuidString.lowercased())
            })
            #expect(attached == c.expected.attached, "\(c.name): attached")
            #expect(ids(resolved.counted) == c.expected.counted, "\(c.name): counted")

            let calendar = TrainingWeek.calendar(timeZone: try #require(TimeZone(identifier: c.timeZone)))
            let streak = StreakCalculator.compute(
                workoutDates: workouts.map(\.start) + resolved.counted.map(\.startedAt), goal: c.goal,
                now: try Self.date(c.now), calendar: calendar)
            #expect(streak.current == c.expected.streak.current, "\(c.name): current streak")
            #expect(streak.longest == c.expected.streak.longest, "\(c.name): longest streak")
            #expect(streak.thisWeekDays == c.expected.streak.thisWeekDays, "\(c.name): this week")
            #expect(streak.thisWeekMet == c.expected.streak.thisWeekMet, "\(c.name): this week met")
        }
    }
}
