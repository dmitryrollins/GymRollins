import Foundation
import Testing
@testable import GymCore

private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
private func inLb(_ kg: Double?) -> Double { UnitConverter.fromKg(kg ?? .nan, to: .lb) }
private let now = Date(timeIntervalSince1970: 1_793_000_000)

@Suite struct ReturnWeightsTests {
    @Test func sixtyPercentRoundsDownOnTheBarbellGrid() {
        let kg = ReturnWeights.weight(from: lb(135), rounder: .barbellLb, minimumKg: lb(45))
        #expect(abs(inLb(kg) - 80) < 0.001)
    }

    @Test func dumbbellAndMachineStepsRoundDownToo() {
        for (usual, light) in [(170.0, 100.0), (110, 65), (195, 115), (100, 60)] {
            let kg = ReturnWeights.weight(from: lb(usual), rounder: .dumbbellLb, minimumKg: lb(2.5))
            #expect(abs(inLb(kg) - light) < 0.001, "\(usual) lb")
        }
    }

    @Test func aGridWithAnOffsetStaysOnIt() {
        // A 45 lb bar with 5 lb the smallest plate loads 45, 55, 65 and so on.
        let rounder = LoadRounder(unit: .lb, step: 10, offset: 5)
        let kg = ReturnWeights.weight(from: lb(135), rounder: rounder, minimumKg: lb(45))
        #expect(abs(inLb(kg) - 75) < 0.001)
    }

    @Test func neverBelowTheEmptyBar() {
        let kg = ReturnWeights.weight(from: lb(55), rounder: .barbellLb, minimumKg: lb(45))
        #expect(abs(inLb(kg) - 45) < 0.001)
    }

    @Test func nothingToLowerIsNil() {
        #expect(ReturnWeights.weight(from: 0, rounder: .barbellLb, minimumKg: lb(45)) == nil)
        #expect(ReturnWeights.weight(from: -1, rounder: .barbellLb, minimumKg: lb(45)) == nil)
    }

    @Test func resumeUnpausesAndPlansWeightedRepExercisesFromNow() {
        let squat = RoutineExercise(exerciseId: "0043", sets: 4, reps: 6, repsMin: 6, weightKg: lb(135), incKg: lb(5))
        let plank = RoutineExercise(exerciseId: "plank", sets: 3, reps: 1, sec: 30, mode: .time)
        let bike = RoutineExercise(exerciseId: "bike", sets: 1, reps: 1, sec: 1200, mode: .cardio)
        let curl = RoutineExercise(exerciseId: "0586", sets: 3, reps: 12, weightKg: lb(100), policy: .off)
        let original = Routine(name: "Legs", emoji: "🦵", policy: .double, paused: true,
                               exercises: [squat, plank, bike, curl])
        let result = ReturnWeights.resume(original, now: now) { _ in lb(80) }
        #expect(!result.routine.paused)
        #expect(result.lowered == 1)
        #expect(result.routine.id == original.id)
        #expect(result.routine.name == "Legs")
        #expect(result.routine.emoji == "🦵")
        #expect(result.routine.policy == .double)
        #expect(result.routine.exercises.map(\.id) == original.exercises.map(\.id))
        let light = result.routine.exercises[0]
        #expect(light.weightKg == lb(80))
        #expect(light.weightSetAt == now)
        #expect(light.sets == 4 && light.reps == 6 && light.repsMin == 6 && light.incKg == lb(5))
        #expect(Array(result.routine.exercises.dropFirst()) == [plank, bike, curl])
    }

    @Test func aWeightTheCallerCantLowerStays() {
        let dip = RoutineExercise(exerciseId: "0251", sets: 3, reps: 10)
        let routine = Routine(name: "Core", paused: true, exercises: [dip])
        let result = ReturnWeights.resume(routine, now: now) { _ in nil }
        #expect(result.lowered == 0)
        #expect(result.routine.exercises == [dip])
        #expect(!result.routine.paused)
    }

    @Test func theRoutinesOffPolicyCountsUnlessTheItemOverridesIt() {
        let inherits = RoutineExercise(exerciseId: "0043", sets: 4, reps: 6, weightKg: lb(135))
        let overrides = RoutineExercise(exerciseId: "0085", sets: 3, reps: 8, weightKg: lb(135), policy: .linear)
        let routine = Routine(name: "Legs", policy: .off, paused: true, exercises: [inherits, overrides])
        let result = ReturnWeights.resume(routine, now: now) { _ in lb(80) }
        #expect(result.lowered == 1)
        #expect(result.routine.exercises[0] == inherits)
        #expect(result.routine.exercises[1].weightKg == lb(80))
        #expect(result.routine.exercises[1].weightSetAt == now)
    }
}
