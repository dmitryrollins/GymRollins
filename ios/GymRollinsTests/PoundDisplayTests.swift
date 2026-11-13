import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Set and plan weights show their pound number in lb (plan 38). Each case uses 47.25 lb stored a little under its kg,
/// which shows "47.3" by its pound number and "47.2" converted from kg, so the test tells the two apart.
@Suite struct PoundDisplayTests {
    private let quarter = PoundWeight(kg: UnitConverter.toKg(47.25, from: .lb) - 0.009, lb: 47.25)
    private let curl = Exercise(id: "0313", name: "dumbbell hammer curl", bodyPart: "upper arms",
                                equipment: "dumbbell", target: "biceps")

    private func set(reps: Int = 8, done: Bool = false) -> WorkoutSet {
        WorkoutSet(weightKg: quarter.kg, weightLb: quarter.lb, reps: reps, done: done)
    }

    private var item: RoutineExercise {
        RoutineExercise(exerciseId: "0313", sets: 3, reps: 10, weightKg: quarter.kg, weightLb: quarter.lb)
    }

    @Test func todaysEditedRowShowsThePoundNumber() {
        #expect(TodayModel.subtitle(sets: [set(), set()], unit: .lb) == "2 \u{00D7} 8 \u{00B7} 47.3 lb (21.4 kg)")
    }

    @Test func todaysPlannedRowShowsThePoundNumber() {
        // A dumbbell step of 0 is no grid: the plan weight is what the row promises.
        let target = PlannedTarget.make(item: item, policy: .double, profile: Profile(unit: .lb, dumbbellStepKg: 0),
                                        exercise: curl, history: [], loads: nil)
        #expect(target.subtitle == "3 \u{00D7} 10 \u{00B7} 47.3 lb (21.4 kg)")
    }

    @Test func aProposalShowsThePlanWeightsPoundNumber() {
        #expect(ProposalModel.prescription(item, unit: .lb) == "3 \u{00D7} 10 @ 47.3 lb")
        #expect(ProposalModel.weight(quarter, .lb) == "47.3 lb")
    }

    @Test func theLogsSummaryShowsThePoundNumber() {
        let entry = WorkoutEntry(exerciseId: "0313", sets: [set(done: true), set(done: true), set(done: true)])
        #expect(WorkoutText.setsSummary(entry, unit: .lb) == "3 \u{00D7} 8 @ 47.3 lb")
        let range = WorkoutEntry(exerciseId: "0313", sets: [
            set(done: true),
            WorkoutSet(weightKg: UnitConverter.toKg(52.25, from: .lb) - 0.009, weightLb: 52.25, reps: 6, done: true),
        ])
        #expect(WorkoutText.setsSummary(range, unit: .lb) == "8, 6 @ 47.3\u{2013}52.3 lb")
    }

    @Test func theLockScreenAndVoiceOverShowThePoundNumber() {
        #expect(WorkoutActivityContent.setDetail(set(), mode: .reps, unit: .lb) == "47.3 lb \u{00D7} 8")
        let label = SetAccessibilityText.rowLabel(set: set(), ordinal: .working(1), mode: .reps, unit: .lb,
                                                  isActive: false, isPlanned: true)
        #expect(label == "Set 1, 8 reps, 47.3 pounds")
    }
}
