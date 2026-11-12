import Foundation

/// Rest between working sets for one exercise: the owner's own choice for it, else a suggestion by its type. Big
/// barbell lifts rest at least `bigLiftSec` and single-muscle moves at most `isolationSec`; everything else rests the
/// default (Settings', or the day's).
public enum ExerciseRest {
    public enum Kind: Equatable, Sendable { case bigLift, isolation, other }

    public static let bigLiftSec = 180
    public static let isolationSec = 90

    /// Name parts that mark a single-muscle move. The library's secondary muscles are too noisy to judge isolation by
    /// (incline fly lists shoulders, rope triceps extension lists shoulders, preacher curl lists forearms).
    static let isolationNameParts = [
        "fly", "flye", "curl", "extension", "raise", "kickback", "cross-over", "crossover", "pushdown", "push-down",
        "pec deck", "shrug", "calf", "wrist",
    ]

    /// Isolation: a single-muscle name, or no secondary muscles. Big lift: otherwise barbell-loaded with at least two
    /// secondary muscles (barbell bench, squat, deadlift, bent-over row). Timed and cardio exercises are `other`.
    public static func kind(of exercise: Exercise) -> Kind {
        guard exercise.mode == .reps else { return .other }
        let name = exercise.name.lowercased()
        if exercise.secondary.isEmpty || isolationNameParts.contains(where: { name.contains($0) }) { return .isolation }
        if exercise.isBarbellLoaded && exercise.secondary.count >= 2 { return .bigLift }
        return .other
    }

    /// bigLift → max(default, 180); isolation → min(default, 90); other, or an unknown exercise → default.
    public static func suggested(for exercise: Exercise?, defaultSec: Int) -> Int {
        guard let exercise else { return defaultSec }
        switch kind(of: exercise) {
        case .bigLift: return max(defaultSec, bigLiftSec)
        case .isolation: return min(defaultSec, isolationSec)
        case .other: return defaultSec
        }
    }

    /// The rest after a working set: the owner's own (`custom`), else the suggestion.
    public static func working(custom: Int?, exercise: Exercise?, defaultSec: Int) -> Int {
        custom ?? suggested(for: exercise, defaultSec: defaultSec)
    }

    /// What to keep as the exercise's own rest when the owner picks `seconds`: nil when it is the suggestion, so the
    /// exercise keeps following the suggestion (and later default changes).
    public static func custom(choosing seconds: Int, exercise: Exercise?, defaultSec: Int) -> Int? {
        seconds == suggested(for: exercise, defaultSec: defaultSec) ? nil : seconds
    }
}
