import Foundation

public extension RoutineExercise {
    static let defaultTimeSec = 30
    static let defaultCardioSec = 1200

    /// Default set/rep/time targets for a routine exercise of `mode` — used when the app adds an exercise and when
    /// a proposal swaps one across modes without its own targets. `barbell` picks the load increment (5 lb vs
    /// 2.5 lb) for rep exercises; timed and cardio exercises have none and carry a mode-compatible policy (`.time`,
    /// `.off`) so they never inherit a routine's load progression.
    static func defaults(exerciseId: String, mode: ExerciseMode, barbell: Bool) -> RoutineExercise {
        switch mode {
        case .reps:
            return RoutineExercise(exerciseId: exerciseId, sets: 3, reps: 10, repsMin: 8, mode: .reps,
                                   incKg: UnitConverter.toKg(barbell ? 5 : 2.5, from: .lb))
        case .time:
            return RoutineExercise(exerciseId: exerciseId, sets: 3, reps: 1, sec: defaultTimeSec, mode: .time,
                                   policy: .time)
        case .cardio:
            return RoutineExercise(exerciseId: exerciseId, sets: 1, reps: 1, sec: defaultCardioSec, mode: .cardio,
                                   policy: .off)
        }
    }
}
