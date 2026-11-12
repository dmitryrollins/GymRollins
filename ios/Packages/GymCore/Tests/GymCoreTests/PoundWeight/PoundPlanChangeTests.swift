import Foundation
import Testing
@testable import GymCore

/// Applying plan changes keeps the pound number with the kg (plan 38): a change's weight sets both, a change with no
/// pound number clears the old one, and edits that leave the weight alone leave its pound number too.
@Suite struct PoundPlanChangeTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let pushId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static var push: String { pushId.uuidString.lowercased() }
    private static func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }

    static let plan = PlanState(routines: [
        Routine(id: pushId, name: "Push", exercises: [
            RoutineExercise(exerciseId: "bench", sets: 3, reps: 10, repsMin: 8, weightKg: lb(135), weightLb: 135),
            RoutineExercise(exerciseId: "incline-db", sets: 3, reps: 10, weightKg: lb(45), weightLb: 45),
        ]),
    ], schedule: [1: pushId])

    private func apply(_ changes: [PlanChange]) throws -> [RoutineExercise] {
        let out = try PlanChangeApplier.apply(changes, to: Self.plan, now: Self.now, mode: { _ in .reps })
        return try #require(out.routines.first { $0.id == Self.pushId }).exercises
    }

    private func item(_ id: String, _ items: [RoutineExercise]) throws -> RoutineExercise {
        try #require(items.first { $0.exerciseId == id })
    }

    @Test func aWeightChangeSetsBothOrClearsThePoundNumber() throws {
        let pounds = try apply([PlanChange(id: "c", type: .weight, routineId: Self.push, exerciseId: "bench",
                                           weightKg: Self.lb(140), weightLb: 140)])
        #expect(try item("bench", pounds).weight == PoundWeight.entered(140, unit: .lb))
        let kg = try apply([PlanChange(id: "c", type: .weight, routineId: Self.push, exerciseId: "bench", weightKg: 60)])
        #expect(try item("bench", kg).weight == PoundWeight(kg: 60, lb: nil))
    }

    @Test func anAddedExerciseTakesTheChangesPoundNumber() throws {
        let out = try apply([PlanChange(id: "c", type: .addExercise, routineId: Self.push, exerciseId: "dips", sets: 3,
                                        reps: 10, weightKg: Self.lb(25), weightLb: 25)])
        #expect(try item("dips", out).weight == PoundWeight.entered(25, unit: .lb))
    }

    @Test func aSwapTakesTheChangesWeightOrNone() throws {
        let given = try apply([PlanChange(id: "c", type: .swapExercise, routineId: Self.push, exerciseId: "bench",
                                          toExerciseId: "db-bench", weightKg: Self.lb(50), weightLb: 50)])
        #expect(try item("db-bench", given).weight == PoundWeight.entered(50, unit: .lb))
        let none = try apply([PlanChange(id: "c", type: .swapExercise, routineId: Self.push, exerciseId: "bench",
                                         toExerciseId: "db-bench")])
        let swapped = try item("db-bench", none)
        #expect(swapped.weightKg == nil && swapped.weightLb == nil)
    }

    @Test func editsThatLeaveTheWeightKeepItsPoundNumber() throws {
        let out = try apply([
            PlanChange(id: "c1", type: .sets, routineId: Self.push, exerciseId: "bench", sets: 4),
            PlanChange(id: "c2", type: .reps, routineId: Self.push, exerciseId: "bench", reps: 12),
            PlanChange(id: "c3", type: .reorder, routineId: Self.push, exerciseId: "incline-db", position: 0),
            PlanChange(id: "c4", type: .superset, routineId: Self.push, exerciseId: "bench",
                       withExerciseId: "incline-db"),
        ])
        #expect(try item("bench", out).weightLb == 135)
        #expect(try item("incline-db", out).weightLb == 45)
    }

    @Test func aReturnWeightNeverKeepsTheOldPoundNumber() throws {
        let routine = Routine(name: "Push", paused: true, exercises: Self.plan.routines[0].exercises)
        let resumed = ReturnWeights.resume(routine, now: Self.now) { $0.exerciseId == "bench" ? Self.lb(80) : nil }
        let bench = try item("bench", resumed.routine.exercises)
        #expect(bench.weightKg == Self.lb(80) && bench.weightLb == nil, "lowered: the kg-only setter clears it")
        #expect(try item("incline-db", resumed.routine.exercises).weightLb == 45, "untouched: kept")
    }

    @Test func aPoundNumberOutOfRangeIsRefused() throws {
        // 1102 lb agrees with 499.86 kg (in range), but pounds stop at 1100, as on the server.
        let change = PlanChange(id: "c", type: .weight, routineId: Self.push, exerciseId: "bench",
                                weightKg: Self.lb(1102), weightLb: 1102)
        #expect(change.weightLb == 1102)
        let violations = Self.validator.validate(PlanProposal(summary: "s", changes: [change]))
        #expect(violations.contains { $0.field == "weightLb" })
        #expect(throws: PlanApplyError.self) { try apply([change]) }
        let fine = PlanChange(id: "c", type: .weight, routineId: Self.push, exerciseId: "bench",
                              weightKg: Self.lb(140), weightLb: 140)
        #expect(Self.validator.validate(PlanProposal(summary: "s", changes: [fine])).isEmpty)
    }

    private static var validator: PlanChangeValidator {
        PlanChangeValidator(plan: PlanSnapshot(routines: [.init(id: push, name: "Push",
                                                                exerciseIds: ["bench", "incline-db"])]),
                            exerciseExists: { _ in true })
    }
}
