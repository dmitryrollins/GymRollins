import Foundation
import Testing
@testable import GymCore

/// The applier must throw — never trap — on values it cannot store, and must normalize a swapped exercise's
/// prescription when the exercise mode changes.
@Suite struct PlanChangeApplierSafetyTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let pushId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static var push: String { pushId.uuidString.lowercased() }
    static let modes: [String: ExerciseMode] = ["bike": .cardio, "plank": .time, "row-erg": .cardio]

    static let plan = PlanState(routines: [
        Routine(id: pushId, name: "Push", exercises: [
            RoutineExercise(exerciseId: "bench", sets: 3, reps: 10, repsMin: 8, weightKg: 59, incKg: 2.27),
            RoutineExercise(exerciseId: "bike", sets: 1, reps: 1, sec: 900, mode: .cardio),
        ]),
    ], schedule: [:])

    private func apply(_ changes: [PlanChange]) throws -> PlanState {
        try PlanChangeApplier.apply(changes, to: Self.plan, now: Self.now, mode: { Self.modes[$0] ?? .reps })
    }

    private func item(_ state: PlanState, _ id: String) -> RoutineExercise? {
        state.routines.first?.exercises.first { $0.exerciseId == id }
    }

    private func expectInvalid(_ change: PlanChange) {
        #expect(throws: PlanApplyError.invalid(change.id)) { try apply([change]) }
    }

    // MARK: Out-of-range values throw

    @Test func addExerciseRejectsUnstorableOptionals() {
        let base = { (minutes: Double?, sec: Int?, weight: Double?, repsMin: Int?) in
            PlanChange(id: "c1", type: .addExercise, routineId: Self.push, exerciseId: "dips", sets: 3, reps: 10,
                       repsMin: repsMin, sec: sec, weightKg: weight, minutes: minutes)
        }
        expectInvalid(base(1e300, nil, nil, nil))
        expectInvalid(base(.nan, nil, nil, nil))
        expectInvalid(base(.infinity, nil, nil, nil))
        expectInvalid(base(nil, 99_999, nil, nil))
        expectInvalid(base(nil, nil, 900, nil))
        expectInvalid(base(nil, nil, .nan, nil))
        expectInvalid(base(nil, nil, nil, 12))
        expectInvalid(PlanChange(id: "c2", type: .addExercise, routineId: Self.push, exerciseId: "dips", sets: 0,
                                 reps: 10))
    }

    @Test func valueEditsRejectOutOfRange() {
        func edit(_ type: PlanChangeType, _ exercise: String, sets: Int? = nil, sec: Int? = nil, weight: Double? = nil,
                  minutes: Double? = nil, inc: Double? = nil) -> PlanChange {
            PlanChange(id: "c1", type: type, routineId: Self.push, exerciseId: exercise, sets: sets, sec: sec,
                       weightKg: weight, minutes: minutes, incKg: inc)
        }
        expectInvalid(edit(.cardio, "bike", minutes: 1e300))
        expectInvalid(edit(.cardio, "bike", minutes: .nan))
        expectInvalid(edit(.weight, "bench", weight: -1))
        expectInvalid(edit(.weight, "bench", weight: .infinity))
        expectInvalid(edit(.inc, "bench", inc: 0))
        expectInvalid(edit(.sec, "bike", sec: 0))
        expectInvalid(edit(.sets, "bench", sets: 0))
    }

    @Test func swapRejectsOutOfRangeTargets() {
        expectInvalid(PlanChange(id: "c1", type: .swapExercise, routineId: Self.push, exerciseId: "bench",
                                 toExerciseId: "db-bench", weightKg: 900))
        expectInvalid(PlanChange(id: "c1", type: .swapExercise, routineId: Self.push, exerciseId: "bench",
                                 toExerciseId: "row-erg", minutes: 1e300))
    }

    @Test func minutesInRangeBecomeSeconds() throws {
        let out = try apply([PlanChange(id: "c1", type: .addExercise, routineId: Self.push, exerciseId: "row-erg",
                                        sets: 1, reps: 1, minutes: 12.5)])
        #expect(item(out, "row-erg")?.sec == 750)
    }

    // MARK: Swap normalizes across modes

    @Test func swapRepsToCardioUsesCardioDefaults() throws {
        let out = try apply([PlanChange(id: "c1", type: .swapExercise, routineId: Self.push, exerciseId: "bench",
                                        toExerciseId: "row-erg")])
        let swapped = try #require(item(out, "row-erg"))
        #expect(swapped.mode == .cardio)
        #expect(swapped.sets == 1 && swapped.reps == 1 && swapped.repsMin == nil && swapped.sec == 1200)
        #expect(swapped.incKg == nil && swapped.weightKg == nil)
    }

    @Test func swapCardioToRepsClearsDurationAndUsesRepDefaults() throws {
        let out = try apply([PlanChange(id: "c1", type: .swapExercise, routineId: Self.push, exerciseId: "bike",
                                        toExerciseId: "dips")])
        let swapped = try #require(item(out, "dips"))
        #expect(swapped.mode == .reps)
        #expect(swapped.sets == 3 && swapped.reps == 10 && swapped.repsMin == 8 && swapped.sec == nil)
    }

    @Test func swapRepsToTimeUsesTimeDefaults() throws {
        let out = try apply([PlanChange(id: "c1", type: .swapExercise, routineId: Self.push, exerciseId: "bench",
                                        toExerciseId: "plank")])
        let swapped = try #require(item(out, "plank"))
        #expect(swapped.mode == .time && swapped.sets == 3 && swapped.reps == 1 && swapped.sec == 30)
    }

    @Test func swapSameModeKeepsPrescription() throws {
        let out = try apply([PlanChange(id: "c1", type: .swapExercise, routineId: Self.push, exerciseId: "bench",
                                        toExerciseId: "db-bench")])
        let swapped = try #require(item(out, "db-bench"))
        #expect(swapped.sets == 3 && swapped.reps == 10 && swapped.repsMin == 8 && swapped.incKg == 2.27)
    }

    @Test func swapSuppliedTargetsWin() throws {
        let out = try apply([
            PlanChange(id: "c1", type: .swapExercise, routineId: Self.push, exerciseId: "bench",
                       toExerciseId: "row-erg", sets: 2, minutes: 15),
            PlanChange(id: "c2", type: .swapExercise, routineId: Self.push, exerciseId: "bike",
                       toExerciseId: "dips", sets: 4, reps: 6, repsMin: 5, weightKg: 20),
        ])
        let cardio = try #require(item(out, "row-erg"))
        #expect(cardio.sets == 2 && cardio.sec == 900)
        let reps = try #require(item(out, "dips"))
        #expect(reps.sets == 4 && reps.reps == 6 && reps.repsMin == 5 && reps.weightKg == 20)
        #expect(reps.weightSetAt == Self.now)
    }

    // MARK: Mode defaults

    @Test func modeDefaultsMatchTheApp() {
        let reps = RoutineExercise.defaults(exerciseId: "x", mode: .reps, barbell: true)
        #expect(reps.sets == 3 && reps.reps == 10 && reps.repsMin == 8 && reps.sec == nil)
        #expect(reps.incKg == UnitConverter.toKg(5, from: .lb))
        #expect(RoutineExercise.defaults(exerciseId: "x", mode: .reps, barbell: false).incKg
            == UnitConverter.toKg(2.5, from: .lb))
        let time = RoutineExercise.defaults(exerciseId: "x", mode: .time, barbell: false)
        #expect(time.sets == 3 && time.reps == 1 && time.sec == 30 && time.incKg == nil)
        let cardio = RoutineExercise.defaults(exerciseId: "x", mode: .cardio, barbell: false)
        #expect(cardio.sets == 1 && cardio.reps == 1 && cardio.sec == 1200 && cardio.mode == .cardio)
    }
}
