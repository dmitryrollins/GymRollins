import Foundation
@testable import GymCore

enum StrengthFixture {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The bundled table (`ios/GymRollins/Resources/strength-standards.json`).
    static func bundled() throws -> StrengthStandards {
        try StrengthStandards.decode(Data(contentsOf: repoRoot
            .appendingPathComponent("ios/GymRollins/Resources/strength-standards.json")))
    }

    /// A tiny table with round numbers: one open-age (23–39) male bench curve with two bins (60 kg and 100 kg)
    /// at percentiles 1/20/50/80/99. At 60 kg: 50/80/100/130/160 kg → thresholds novice 45, intermediate 65,
    /// advanced 80, elite 130.
    static func synthetic(levels: String? = nil, formatVersion: Int = 1, kg60: String = "[50, 80, 100, 130, 160]",
                          bw60: Int = 60) -> Data {
        let lv = levels ?? """
        [{"id":"beginner","name":"Beginner","percentile":50,"fraction":0},
         {"id":"novice","name":"Novice","percentile":50,"fraction":0.45},
         {"id":"intermediate","name":"Intermediate","percentile":50,"fraction":0.65},
         {"id":"advanced","name":"Advanced","percentile":20,"fraction":1},
         {"id":"elite","name":"Elite","percentile":80,"fraction":1}]
        """
        return Data("""
        {"formatVersion":\(formatVersion),
         "source":{"name":"Test","url":"https://example.org","license":"PD","version":"t"},
         "percentiles":[1,20,50,80,99],
         "ageGroups":[{"id":"u23","label":"Under 23","min":14,"max":22},{"id":"open","label":"23–39","min":23,"max":39}],
         "levels":\(lv),
         "tables":{"M":{"bench":{"open":[{"bw":\(bw60),"n":100,"kg":\(kg60)},{"bw":100,"n":50,"kg":[70,100,120,150,200]}]}}}}
        """.utf8)
    }

    static func syntheticStandards() throws -> StrengthStandards { try StrengthStandards.decode(synthetic()) }

    static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    static func utc() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func workout(_ start: String, _ exerciseId: String, kg: Double, reps: Int, warmup: Bool = false,
                        done: Bool = true) -> Workout {
        Workout(startedAt: date(start), endedAt: date(start).addingTimeInterval(3_600), name: "W",
                entries: [WorkoutEntry(exerciseId: exerciseId,
                                       sets: [WorkoutSet(weightKg: kg, reps: reps, done: done, warmup: warmup)])])
    }
}
