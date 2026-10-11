import Foundation
@testable import GymCore

/// Small builders shared by the insights tests (library rows copied from the bundled exercises.json).
enum InsightsFixture {
    static let bench = Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell",
                                target: "pectorals", secondary: ["triceps", "shoulders"])
    static let pulldown = Exercise(id: "0198", name: "cable pulldown", bodyPart: "back", equipment: "cable",
                                   target: "lats", secondary: ["biceps", "forearms"])
    static let curl = Exercise(id: "0313", name: "dumbbell hammer curl", bodyPart: "upper arms",
                               equipment: "dumbbell", target: "biceps", secondary: ["forearms"])
    static let squat = Exercise(id: "0043", name: "barbell full squat", bodyPart: "upper legs", equipment: "barbell",
                                target: "glutes", secondary: ["quadriceps", "hamstrings", "calves", "core"])
    static let pushUp = Exercise(id: "0662", name: "push-up", bodyPart: "chest", equipment: "body weight",
                                 target: "pectorals", secondary: ["triceps", "shoulders"])
    static let plank = Exercise(id: "plank", name: "plank", bodyPart: "waist", equipment: "body weight",
                                target: "abs", mode: .time)
    static let run = Exercise(id: "run", name: "run", bodyPart: "cardio", equipment: "body weight",
                              target: "cardiovascular system")
    static let customLegs = Exercise(id: "custom-sled", name: "sled push", bodyPart: "upper legs",
                                     equipment: "sled machine", target: "upper legs", isCustom: true)

    static let all = [bench, pulldown, curl, squat, pushUp, plank, run, customLegs]
    static func lookup(_ id: String) -> Exercise? { all.first { $0.id == id } }

    static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    static func sets(_ count: Int, kg: Double = 60, reps: Int = 8, warmup: Bool = false, done: Bool = true,
                     rir: Double? = nil, rpe: Double? = nil, sec: Int? = nil) -> [WorkoutSet] {
        (0..<count).map { _ in
            WorkoutSet(weightKg: kg, reps: reps, sec: sec, done: done, warmup: warmup, rir: rir, rpe: rpe)
        }
    }

    /// A finished workout that ends one hour after `start`.
    static func workout(_ start: String, _ entries: [(String, [WorkoutSet])], endedAt: String? = nil) -> Workout {
        let started = date(start)
        return Workout(startedAt: started, endedAt: endedAt.map(date) ?? started.addingTimeInterval(3_600),
                       name: "W", entries: entries.map { WorkoutEntry(exerciseId: $0.0, sets: $0.1) })
    }

    static func utc() -> Calendar { TrainingWeek.calendar(timeZone: TimeZone(identifier: "UTC")!) }
}
