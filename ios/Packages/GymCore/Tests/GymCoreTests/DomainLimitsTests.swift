import Foundation
import Testing
@testable import GymCore

@Suite struct DomainLimitsTests {
    private func routine(name: String, exercises: Int) -> Routine {
        Routine(name: name, exercises: (0..<exercises).map { RoutineExercise(exerciseId: "e\($0)", sets: 3, reps: 8) })
    }

    @Test func routineNameAndExerciseCount() {
        #expect(DomainLimits.routineViolation(routine(name: "Push", exercises: 3)) == nil)
        #expect(DomainLimits.routineViolation(routine(name: String(repeating: "a", count: 40), exercises: 20)) == nil)
        #expect(DomainLimits.routineViolation(routine(name: "  ", exercises: 1))
            == "Give the routine a name.")
        #expect(DomainLimits.routineViolation(routine(name: String(repeating: "a", count: 41), exercises: 1))
            == "Routine names can be up to 40 characters.")
        #expect(DomainLimits.routineViolation(routine(name: "Push", exercises: 21))
            == "A routine can have up to 20 exercises.")
    }

    @Test func customExerciseName() {
        #expect(DomainLimits.customExerciseNameViolation("Sled push") == nil)
        #expect(DomainLimits.customExerciseNameViolation(String(repeating: "x", count: 80)) == nil)
        #expect(DomainLimits.customExerciseNameViolation("") == "Name required")
        #expect(DomainLimits.customExerciseNameViolation(String(repeating: "x", count: 81))
            == "Names can be up to 80 characters.")
    }

    @Test func bodyweight() {
        #expect(DomainLimits.bodyweightViolation(weightKg: 81, bodyFatPct: 15) == nil)
        #expect(DomainLimits.bodyweightViolation(weightKg: 29.9, bodyFatPct: nil) == "Enter a weight between 30 and 300 kg")
        #expect(DomainLimits.bodyweightViolation(weightKg: 301, bodyFatPct: nil) == "Enter a weight between 30 and 300 kg")
        #expect(DomainLimits.bodyweightViolation(weightKg: 80, bodyFatPct: 2) == "Enter a body fat between 3 and 60%")
        #expect(DomainLimits.bodyweightViolation(weightKg: 80, bodyFatPct: 61) == "Enter a body fat between 3 and 60%")
    }

    @Test func setValues() {
        #expect(DomainLimits.setWeightKg.contains(1_000) && !DomainLimits.setWeightKg.contains(1_000.1))
        #expect(DomainLimits.setReps.contains(1_000) && !DomainLimits.setReps.contains(1_001))
        #expect(DomainLimits.setSeconds.contains(86_400) && !DomainLimits.setSeconds.contains(86_401))
        #expect(DomainLimits.setMinutes.contains(1_440) && !DomainLimits.setMinutes.contains(1_441))
        #expect(DomainLimits.setDistanceM.contains(1_000_000) && !DomainLimits.setDistanceM.contains(1_000_001))
    }

    @Test func profileRanges() {
        #expect(DomainLimits.profileViolation(restSec: 120, warmupRestSec: 60, heightCm: nil, goalWeightKg: nil,
                                              trainingDays: 4, limits: "", deloadPct: 0.05) == nil)
        #expect(DomainLimits.profileViolation(restSec: 901, warmupRestSec: 60, heightCm: nil, goalWeightKg: nil,
                                              trainingDays: 4, limits: "", deloadPct: 0.05) != nil)
        #expect(DomainLimits.profileViolation(restSec: 120, warmupRestSec: 60, heightCm: 99, goalWeightKg: nil,
                                              trainingDays: 4, limits: "", deloadPct: 0.05) != nil)
        #expect(DomainLimits.profileViolation(restSec: 120, warmupRestSec: 60, heightCm: nil, goalWeightKg: 301,
                                              trainingDays: 4, limits: "", deloadPct: 0.05) != nil)
        #expect(DomainLimits.profileViolation(restSec: 120, warmupRestSec: 60, heightCm: nil, goalWeightKg: nil,
                                              trainingDays: 8, limits: "", deloadPct: 0.05) != nil)
        #expect(DomainLimits.profileViolation(restSec: 120, warmupRestSec: 60, heightCm: nil, goalWeightKg: nil,
                                              trainingDays: 4, limits: String(repeating: "x", count: 501),
                                              deloadPct: 0.05) != nil)
        #expect(DomainLimits.profileViolation(restSec: 120, warmupRestSec: 60, heightCm: nil, goalWeightKg: nil,
                                              trainingDays: 4, limits: "", deloadPct: 0.6) != nil)
    }

    @Test func planValidatorSharesTheLimits() {
        #expect(PlanChangeValidator.maxName == DomainLimits.routineNameMax)
        #expect(PlanChangeValidator.maxExercisesPerRoutine == DomainLimits.routineExercisesMax)
    }
}
