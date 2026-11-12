import Foundation
import GymCore

/// Rest per exercise (`ExerciseRestStore` + the `ExerciseRest` suggestion): what the workout session and Today's
/// plan editor read and write through their injected closures.
extension AppEnvironment {
    /// The rest after a working set of `exerciseId`, with `defaultSec` as the workout's (or the day's) default.
    func workingRest(exerciseId: String, defaultSec: Int) -> Int {
        ExerciseRest.working(custom: exerciseRests.custom(exerciseId), exercise: library.exercise(exerciseId),
                             defaultSec: defaultSec)
    }

    /// Keeps `seconds` as the exercise's rest in every workout. Its suggestion is kept as none, so the exercise
    /// follows the suggestion again (and later default changes).
    func setWorkingRest(_ seconds: Int, exerciseId: String, defaultSec: Int) {
        let exercise = library.exercise(exerciseId)
        exerciseRests.set(ExerciseRest.custom(choosing: seconds, exercise: exercise, defaultSec: defaultSec),
                          for: exerciseId)
    }
}
