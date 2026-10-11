import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@Suite struct ProposalModelTests {
    private static func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let pushId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let legsId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private static var push: String { pushId.uuidString.lowercased() }
    private static var legs: String { legsId.uuidString.lowercased() }

    private let library = ExerciseLibrary(exercises: [
        Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
        Exercise(id: "0314", name: "dumbbell incline bench press", bodyPart: "chest", equipment: "dumbbell",
                 target: "pectorals"),
        Exercise(id: "0251", name: "chest dip", bodyPart: "chest", equipment: "body weight", target: "pectorals"),
        Exercise(id: "0585", name: "lever leg extension", bodyPart: "upper legs", equipment: "leverage machine",
                 target: "quads"),
        Exercise(id: "0003", name: "air bike", bodyPart: "cardio", equipment: "body weight", target: "cardio"),
    ])

    private let plan = PlanState(routines: [
        Routine(id: pushId, name: "Push + Arms", exercises: [
            RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, repsMin: 8, weightKg: lb(130), incKg: lb(5)),
            RoutineExercise(exerciseId: "0314", sets: 3, reps: 10, weightKg: lb(45)),
            RoutineExercise(exerciseId: "0003", sets: 1, reps: 1, sec: 1200, mode: .cardio),
        ]),
        Routine(id: legsId, name: "Legs", exercises: [
            RoutineExercise(exerciseId: "0585", sets: 3, reps: 12, weightKg: lb(110)),
        ]),
    ], schedule: [6: legsId])

    private func rows(_ changes: [PlanChange], unit: WeightUnit = .lb,
                      invalid: [String: String] = [:]) -> [ProposalModel.Row] {
        ProposalModel.rows(for: changes, plan: plan, library: library, unit: unit, now: Self.now, violations: invalid)
    }

    private func text(_ change: PlanChange, unit: WeightUnit = .lb) -> String {
        rows([change], unit: unit).first?.text ?? ""
    }

    @Test func weightShowsBeforeAndAfterInTheOwnersUnit() {
        let change = PlanChange(id: "c1", type: .weight, routineId: Self.push, exerciseId: "0025",
                                weightKg: Self.lb(140), reason: "Hit top of range")
        let row = rows([change]).first
        #expect(row?.label == "Weight")
        #expect(row?.text == "Barbell Bench Press: 3 \u{00D7} 8\u{2013}10 @ 130 lb \u{2192} 3 \u{00D7} 8\u{2013}10 @ 140 lb")
        #expect(row?.reason == "Hit top of range")
        #expect(row?.invalidReason == nil)
        #expect(text(change, unit: .kg).hasSuffix("@ 59 kg \u{2192} 3 \u{00D7} 8\u{2013}10 @ 63.5 kg"))
    }

    @Test func setsRepsAndRepsMin() {
        #expect(text(PlanChange(id: "c1", type: .sets, routineId: Self.push, exerciseId: "0025", sets: 4))
            == "Barbell Bench Press: 3 \u{00D7} 8\u{2013}10 @ 130 lb \u{2192} 4 \u{00D7} 8\u{2013}10 @ 130 lb")
        #expect(text(PlanChange(id: "c1", type: .reps, routineId: Self.push, exerciseId: "0025", reps: 8, repsMin: 6))
            == "Barbell Bench Press: 3 \u{00D7} 8\u{2013}10 @ 130 lb \u{2192} 3 \u{00D7} 6\u{2013}8 @ 130 lb")
        #expect(text(PlanChange(id: "c1", type: .repsMin, routineId: Self.push, exerciseId: "0314", repsMin: 8))
            == "Dumbbell Incline Bench Press: 3 \u{00D7} 10 @ 45 lb \u{2192} 3 \u{00D7} 8\u{2013}10 @ 45 lb")
        #expect(rows([PlanChange(id: "c1", type: .reps, routineId: Self.push, exerciseId: "0025", reps: 12)]).first?.label
            == "Reps")
    }

    @Test func timeAndCardio() {
        #expect(text(PlanChange(id: "c1", type: .sec, routineId: Self.push, exerciseId: "0314", sec: 45))
            == "Dumbbell Incline Bench Press: 3 \u{00D7} 10 @ 45 lb \u{2192} 3 \u{00D7} 45 s @ 45 lb")
        #expect(text(PlanChange(id: "c1", type: .cardio, routineId: Self.push, exerciseId: "0003", minutes: 30))
            == "Air Bike: 20 min \u{2192} 30 min")
    }

    @Test func exerciseEdits() {
        #expect(text(PlanChange(id: "c1", type: .addExercise, routineId: Self.push, exerciseId: "0251", sets: 3,
                                reps: 10)) == "Chest Dip: 3 \u{00D7} 10 \u{2192} added to Push + Arms")
        #expect(text(PlanChange(id: "c1", type: .removeExercise, routineId: Self.legs, exerciseId: "0585"))
            == "Lever Leg Extension \u{2014} removed from Legs")
        #expect(text(PlanChange(id: "c1", type: .swapExercise, routineId: Self.push, exerciseId: "0314",
                                toExerciseId: "0251")) == "Dumbbell Incline Bench Press \u{2192} Chest Dip")
        #expect(text(PlanChange(id: "c1", type: .reorder, routineId: Self.push, exerciseId: "0314", position: 0))
            == "Dumbbell Incline Bench Press \u{2192} #1 in Push + Arms")
        #expect(text(PlanChange(id: "c1", type: .superset, routineId: Self.push, exerciseId: "0025",
                                withExerciseId: "0314")) == "Barbell Bench Press + Dumbbell Incline Bench Press")
    }

    @Test func progression() {
        #expect(text(PlanChange(id: "c1", type: .routineProg, routineId: Self.push, policy: .linear))
            == "Push + Arms: Double \u{2192} Linear")
        #expect(text(PlanChange(id: "c1", type: .exerciseProg, routineId: Self.push, exerciseId: "0025", policy: .greyskull))
            == "Barbell Bench Press: Double \u{2192} Greyskull")
        #expect(text(PlanChange(id: "c1", type: .inc, routineId: Self.push, exerciseId: "0025", incKg: Self.lb(2.5)))
            == "Barbell Bench Press: +5 lb \u{2192} +2.5 lb")
    }

    @Test func routineEditsAndLabels() {
        let all = rows([
            PlanChange(id: "a", type: .addRoutine, routineId: "upper", name: "Upper weak points"),
            PlanChange(id: "b", type: .addExercise, routineId: "upper", exerciseId: "0251", sets: 3, reps: 10),
            PlanChange(id: "c", type: .removeRoutine, routineId: Self.legs),
            PlanChange(id: "d", type: .renameRoutine, routineId: Self.push, name: "Chest"),
            PlanChange(id: "e", type: .pauseRoutine, routineId: Self.push, paused: true),
            PlanChange(id: "f", type: .pauseRoutine, routineId: Self.push, paused: false),
        ])
        #expect(all.map(\.label) == ["New routine", "Add", "Remove", "Rename", "Pause", "Resume"])
        #expect(all.map(\.text) == [
            "Upper weak points", "Chest Dip: 3 \u{00D7} 10 \u{2192} added to Upper weak points",
            "Legs \u{2014} routine removed", "Push + Arms \u{2192} Chest", "Chest \u{2014} paused", "Chest \u{2014} resumed",
        ])
    }

    @Test func scheduleUsesDayNamesAndRest() {
        let all = rows([
            PlanChange(id: "c1", type: .week, routineId: Self.push, weekday: 6),
            PlanChange(id: "c2", type: .week, weekday: 6),
        ])
        #expect(all.map(\.label) == ["Schedule", "Schedule"])
        #expect(all.map(\.text) == ["Sat: Legs \u{2192} Push + Arms", "Sat: Push + Arms \u{2192} Rest"])
    }

    @Test func invalidChangesCarryTheirReason() {
        let change = PlanChange(id: "c9", type: .sets, routineId: "nope", exerciseId: "0025", sets: 3)
        let row = rows([change], invalid: ["c9": "Unknown routine 'nope'"]).first
        #expect(row?.invalidReason == "Unknown routine 'nope'")
        #expect(row?.text == "Barbell Bench Press: 3 sets")
    }
}
