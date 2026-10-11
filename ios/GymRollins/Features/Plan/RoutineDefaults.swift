import GymCore
import GymData

/// Default set/rep/time targets for a newly-added routine exercise, chosen from its mode. The mode defaults live
/// in GymCore (`RoutineExercise.defaults`) so the proposal applier uses the same ones.
enum RoutineDefaults {
    static func item(for exercise: Exercise, profile: Profile) -> RoutineExercise {
        RoutineExercise.defaults(exerciseId: exercise.id, mode: exercise.mode,
                                 barbell: LoadRounding.isBarbellType(exercise.equipment))
    }
}
