import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// The green "+x" on Today's row only shows when the weight really rose.
@Suite struct PlannedTargetBadgeTests {
    private let bell = Exercise(id: "kb-curl", name: "kettlebell curl", bodyPart: "upper arms", equipment: "kettlebell",
                                target: "biceps")

    private func make(history kg: Double, itemKg: Double, unit: WeightUnit, inc: Double = 1.13398,
                      loads: ListingLoads?, profile: Profile? = nil) -> PlannedTarget {
        let item = RoutineExercise(exerciseId: "kb-curl", sets: 3, reps: 10, repsMin: 8, weightKg: itemKg, incKg: inc)
        return PlannedTarget.make(item: item, policy: .double, profile: profile ?? Profile(unit: unit), exercise: bell,
                                  history: [SessionResult(date: .now, weightKg: kg, reps: [10, 10, 10])], loads: loads)
    }

    /// 44 lb is 19.96 kg and the gym's bell is 20: the same bell, not a rise.
    @Test func aBellSavedBeforeTheChipFixIsNotARise() {
        let target = make(history: UnitConverter.toKg(44, from: .lb), itemKg: UnitConverter.toKg(44, from: .lb),
                          unit: .lb, loads: .fixed(kg: [20, 24]))
        #expect(target.suggestedKg == 20)
        #expect(target.badge == nil, "was \(target.badge ?? "nil")")
    }

    @Test func aReSavedChipIsNotARise() {
        let target = make(history: 24.0, itemKg: 24.0, unit: .lb, loads: .fixed(kg: [24.04]))
        #expect(target.suggestedKg == 24.04)
        #expect(target.badge == nil, "was \(target.badge ?? "nil")")
    }

    @Test func aRealRiseAtTheGymStillShows() {
        let target = make(history: 16, itemKg: 16, unit: .kg, loads: .fixed(kg: [20, 24]))
        #expect(target.badge?.hasPrefix("+4") == true, "was \(target.badge ?? "nil")")
    }

    /// With no gym there is nothing to snap to, so a 0.2 kg micro-plate rise is a rise.
    @Test func aMicroPlateRiseWithoutAGymStillShows() throws {
        let dumbbell = Exercise(id: "kb-curl", name: "dumbbell curl", bodyPart: "upper arms", equipment: "dumbbell",
                                target: "biceps")
        let item = RoutineExercise(exerciseId: "kb-curl", sets: 3, reps: 10, repsMin: 8, weightKg: 20, incKg: 0.2)
        let target = PlannedTarget.make(
            item: item, policy: .double, profile: Profile(unit: .kg, dumbbellStepKg: 0.2), exercise: dumbbell,
            history: [SessionResult(date: .now, weightKg: 20, reps: [10, 10, 10])], loads: nil)
        #expect(target.suggestedKg.map { abs($0 - 20.2) < 0.001 } == true, "was \(String(describing: target.suggestedKg))")
        #expect(target.badge != nil, "the 0.2 kg rise shows")
    }
}
