import Foundation
@testable import GymCore

/// Builders for the calorie tests. The MET values mirror `met-values.json` (the app test checks that file).
enum CalorieFixture {
    static let table = METTable(source: METSource(title: "test", citation: "test", url: "https://pacompendium.com",
                                                  retrieved: "2026-09-30", terms: []),
                                activities: [
        ("02050", 6.0), ("02052", 5.0), ("02054", 3.5), ("02055", 5.8),
        ("02034", 3.5), ("02035", 5.0), ("02040", 7.5),
        ("02020", 7.5), ("02022", 3.8), ("02024", 2.8),
        ("12150", 8.0), ("17200", 4.8), ("17035", 7.0), ("01200", 6.8), ("02048", 5.0), ("02049", 9.0),
        ("02065", 9.3), ("02068", 11.0), ("02070", 7.3), ("02071", 5.0), ("02080", 6.8), ("02115", 2.8),
        ("02210", 7.0), ("02214", 11.0), ("02060", 5.5),
    ].map { METActivity(code: $0.0, met: $0.1, description: "d", heading: "h") })

    static let bench = Exercise(id: "bench", name: "barbell bench press", bodyPart: "chest", equipment: "barbell",
                                target: "pectorals")
    static let curl = Exercise(id: "curl", name: "dumbbell hammer curl", bodyPart: "upper arms",
                               equipment: "dumbbell", target: "biceps")
    static let fly = Exercise(id: "fly", name: "cable standing fly", bodyPart: "chest", equipment: "cable",
                              target: "pectorals")
    static let squat = Exercise(id: "squat", name: "barbell full squat", bodyPart: "upper legs", equipment: "barbell",
                                target: "glutes")
    static let pushUp = Exercise(id: "pushup", name: "push-up", bodyPart: "chest", equipment: "body weight",
                                 target: "pectorals")
    static let run = Exercise(id: "run", name: "run", bodyPart: "cardio", equipment: "body weight",
                              target: "cardiovascular system")
    static let bike = Exercise(id: "bike", name: "stationary bike walk", bodyPart: "cardio",
                               equipment: "leverage machine", target: "cardiovascular system")
    static let burpee = Exercise(id: "burpee", name: "burpee", bodyPart: "cardio", equipment: "body weight",
                                 target: "cardiovascular system")

    static let all = [bench, curl, fly, squat, pushUp, run, bike, burpee]
    static func lookup(_ id: String) -> Exercise? { all.first { $0.id == id } }

    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static func sets(_ count: Int, kg: Double = 60, reps: Int = 8, warmup: Bool = false, done: Bool = true,
                     rir: Double? = nil, rpe: Double? = nil, minutes: Double? = nil, sec: Int? = nil) -> [WorkoutSet] {
        (0..<count).map { _ in
            WorkoutSet(weightKg: kg, reps: reps, sec: sec, minutes: minutes, done: done, warmup: warmup, rir: rir,
                       rpe: rpe)
        }
    }

    static func workout(minutes: Double, paused: TimeInterval = 0, ended: Bool = true,
                        _ entries: [(String, [WorkoutSet])], groups: [String?]? = nil) -> Workout {
        let list = entries.enumerated().map { index, item in
            WorkoutEntry(exerciseId: item.0, sets: item.1, supersetGroup: groups?[index])
        }
        return Workout(startedAt: start, endedAt: ended ? start.addingTimeInterval(minutes * 60 + paused) : nil,
                       pausedSeconds: paused, name: "W", entries: list)
    }

    static func estimate(_ workout: Workout, kg: Double? = 80) -> CalorieEstimate? {
        CalorieEstimator.estimate(workout: workout, exercise: lookup, bodyWeightKg: kg, table: table)
    }
}
