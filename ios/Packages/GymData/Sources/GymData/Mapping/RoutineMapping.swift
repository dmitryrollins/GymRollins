import Foundation
import GymCore

extension RoutineRecord {
    public var value: Routine {
        Routine(id: id, name: name, emoji: emoji, policy: ProgressionPolicy(rawValue: policyRaw) ?? .double,
                paused: paused, exercises: exercises.sorted { $0.position < $1.position }.map(\.value))
    }
}

extension RoutineExerciseRecord {
    public var value: RoutineExercise {
        RoutineExercise(id: id, exerciseId: exerciseId, sets: sets, reps: reps, repsMin: repsMin, sec: sec,
                        weightKg: weightKg, mode: ExerciseMode(rawValue: modeRaw) ?? .reps,
                        policy: policyRaw.flatMap(ProgressionPolicy.init(rawValue:)), incKg: incKg,
                        supersetGroup: supersetGroup, weightSetAt: weightSetAt)
    }

    public convenience init(_ value: RoutineExercise, position: Int) {
        self.init(id: value.id, exerciseId: value.exerciseId, position: position, sets: value.sets, reps: value.reps,
                  repsMin: value.repsMin, sec: value.sec, weightKg: value.weightKg, weightSetAt: value.weightSetAt,
                  modeRaw: value.mode.rawValue,
                  policyRaw: value.policy?.rawValue, incKg: value.incKg, supersetGroup: value.supersetGroup)
    }
}
