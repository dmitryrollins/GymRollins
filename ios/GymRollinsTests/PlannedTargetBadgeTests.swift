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

    // MARK: Timed and cardio rows say the time

    private func target(mode: ExerciseMode, sets: Int, sec: Int, equipment: String = "body weight") -> PlannedTarget {
        let exercise = Exercise(id: "t", name: "plank", bodyPart: mode == .cardio ? "cardio" : "waist", equipment: equipment,
                                target: "abs", mode: mode)
        let item = RoutineExercise(exerciseId: "t", sets: sets, reps: mode == .time ? 0 : 1, sec: sec, mode: mode,
                                   policy: mode == .cardio ? .off : .time)
        return PlannedTarget.make(item: item, policy: .off, profile: Profile(), exercise: exercise, history: [], loads: nil)
    }

    @Test func aCardioRowSaysItsMinutes() {
        #expect(target(mode: .cardio, sets: 1, sec: 600).subtitle == "1 \u{00D7} 10 min")
    }

    @Test func aTimedRowSaysItsSeconds() {
        #expect(target(mode: .time, sets: 3, sec: 45).subtitle == "3 \u{00D7} 45 s")
    }

    @Test func aTimeThatIsNotWholeMinutesStaysInSeconds() {
        #expect(target(mode: .time, sets: 2, sec: 90).subtitle == "2 \u{00D7} 90 s")
        #expect(target(mode: .time, sets: 2, sec: 120).subtitle == "2 \u{00D7} 2 min")
    }

    @Test func aTimedRowWithALoadKeepsTheLoad() {
        let exercise = Exercise(id: "t", name: "farmer hold", bodyPart: "waist", equipment: "dumbbell", target: "abs", mode: .time)
        let item = RoutineExercise(exerciseId: "t", sets: 3, reps: 0, sec: 30, weightKg: 20, mode: .time, policy: .off)
        let text = PlannedTarget.make(item: item, policy: .off, profile: Profile(unit: .kg), exercise: exercise,
                                      history: [SessionResult(date: .now, weightKg: 20, reps: [0], secs: [30])],
                                      loads: nil).subtitle
        #expect(text.hasPrefix("3 \u{00D7} 30 s \u{00B7} 20"))
    }
}
