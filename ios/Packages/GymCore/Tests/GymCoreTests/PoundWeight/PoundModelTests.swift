import Foundation
import Testing
@testable import GymCore

/// Sets, plan items and plan changes keep a weight's pound number next to its kg (plan 38): never one that disagrees,
/// copied with the kg, cleared when the kg changes without one.
@Suite struct PoundModelTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private var pounds45: PoundWeight { PoundWeight.entered(45, unit: .lb) }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    // MARK: WorkoutSet

    @Test func aSetKeepsAnAgreeingPoundNumberAndDropsAnotherOne() {
        #expect(WorkoutSet(weightKg: lb(45), weightLb: 45, reps: 5).weightLb == 45)
        #expect(WorkoutSet(weightKg: 20.3, weightLb: 45, reps: 5).weightLb == nil)
        #expect(WorkoutSet(weightKg: 20, reps: 5).weightLb == nil)
        #expect(WorkoutSet(weightKg: lb(45), weightLb: 45, reps: 5).weight == pounds45)
    }

    @Test func aSetDecodesItsPoundNumberAndDropsADisagreeingOne() throws {
        let id = UUID().uuidString
        let kept = try decode(WorkoutSet.self, #"{"id":"\#(id)","weightKg":20.41165665,"weightLb":45,"reps":5}"#)
        #expect(kept.weightLb == 45)
        let dropped = try decode(WorkoutSet.self, #"{"id":"\#(id)","weightKg":20.3,"weightLb":45,"reps":5}"#)
        #expect(dropped.weightLb == nil && dropped.weightKg == 20.3)
        let old = try decode(WorkoutSet.self, #"{"id":"\#(id)","weightKg":20.3,"reps":5}"#)
        #expect(old.weightLb == nil)
        let set = WorkoutSet(weightKg: lb(47.5), weightLb: 47.5, reps: 5)
        #expect(try roundTrip(set) == set)
    }

    @Test func everySetCopyKeepsThePoundNumber() {
        let set = WorkoutSet(weightKg: lb(45), weightLb: 45, reps: 5, sec: 30)
        let copies = [
            set.completing(at: Date(timeIntervalSince1970: 1)), set.with(sec: 40), set.with(multiplier: 2),
            set.with(minutes: 1, distanceM: 100), set.with(rir: 2), set.with(weightKg: set.weightKg, reps: 8),
            set.duplicatedUndone(),
        ]
        #expect(copies.allSatisfy { $0.weightLb == 45 && $0.weightKg == set.weightKg })
    }

    @Test func aNewKgWithoutAPoundNumberClearsIt() {
        let set = WorkoutSet(weightKg: lb(45), weightLb: 45, reps: 5)
        let changed = set.with(weightKg: 20, reps: 5)
        #expect(changed.weightKg == 20 && changed.weightLb == nil)
    }

    @Test func aNewWeightSetsBoth() {
        let set = WorkoutSet(weightKg: 20, reps: 5)
        let changed = set.with(weight: PoundWeight.entered(47.5, unit: .lb), reps: 6)
        #expect(changed.weightKg == lb(47.5) && changed.weightLb == 47.5 && changed.reps == 6 && changed.id == set.id)
        let kg = changed.with(weight: PoundWeight.entered(22, unit: .kg), reps: 6)
        #expect(kg.weightKg == 22 && kg.weightLb == nil)
    }

    @Test func addingASetCopiesTheLastWorkingSetsPoundNumber() throws {
        let entry = WorkoutEntry(exerciseId: "bench", sets: [WorkoutSet(weightKg: lb(45), weightLb: 45, reps: 5)])
        let workout = Workout(startedAt: .now, name: "W", entries: [entry]).appendingSet(entryId: entry.id)
        let added = try #require(workout.entries.first?.sets.last)
        #expect(workout.entries[0].sets.count == 2 && added.weightLb == 45)
    }

    // MARK: RoutineExercise

    @Test func aPlanItemKeepsAnAgreeingPoundNumberAndDropsAnotherOne() {
        #expect(RoutineExercise(exerciseId: "b", sets: 3, reps: 5, weightKg: lb(45), weightLb: 45).weightLb == 45)
        #expect(RoutineExercise(exerciseId: "b", sets: 3, reps: 5, weightKg: 20.3, weightLb: 45).weightLb == nil)
        #expect(RoutineExercise(exerciseId: "b", sets: 3, reps: 5, weightLb: 45).weightLb == nil, "no kg, no pounds")
        let fixed = RoutineExercise(exerciseId: "b", sets: 3, reps: 5, fixedWeightKg: lb(45), fixedWeightLb: 45)
        #expect(fixed.fixedWeightLb == 45 && fixed.fixedWeight == pounds45)
        #expect(RoutineExercise(exerciseId: "b", sets: 3, reps: 5, fixedWeightKg: 20.3, fixedWeightLb: 45)
            .fixedWeightLb == nil)
        #expect(RoutineExercise(exerciseId: "b", sets: 3, reps: 5, weightKg: lb(45), weightLb: 45).weight == pounds45)
        #expect(RoutineExercise(exerciseId: "b", sets: 3, reps: 5).weight == nil)
    }

    @Test func aPlanItemDecodesItsPoundNumbersAndDropsDisagreeingOnes() throws {
        let item = RoutineExercise(exerciseId: "b", sets: 3, reps: 5, weightKg: lb(45), weightLb: 45,
                                   fixedWeightKg: lb(50), fixedWeightLb: 50)
        #expect(try roundTrip(item) == item)
        let id = UUID().uuidString
        let off = try decode(RoutineExercise.self, """
            {"id":"\(id)","exerciseId":"b","sets":3,"reps":5,"weightKg":20.3,"weightLb":45,
             "fixedWeightKg":20.3,"fixedWeightLb":45}
            """)
        #expect(off.weightLb == nil && off.fixedWeightLb == nil && off.weightKg == 20.3)
        let old = try decode(RoutineExercise.self, #"{"id":"\#(id)","exerciseId":"b","sets":3,"reps":5,"weightKg":20}"#)
        #expect(old.weightLb == nil)
    }

    @Test func plannedWeightSettersKeepOrClearOrSetThePoundNumber() {
        let date = Date(timeIntervalSince1970: 5)
        let item = RoutineExercise(exerciseId: "b", sets: 3, reps: 5, weightKg: lb(45), weightLb: 45)
        #expect(item.with(weightKg: lb(45), setAt: date).weightLb == 45, "same kg: kept")
        let lowered = item.with(weightKg: 12, setAt: date)
        #expect(lowered.weightKg == 12 && lowered.weightLb == nil && lowered.weightSetAt == date)
        let chosen = item.with(weight: PoundWeight.entered(50, unit: .lb), setAt: date)
        #expect(chosen.weightKg == lb(50) && chosen.weightLb == 50 && chosen.weightSetAt == date)
        #expect(item.with(fixedWeightKg: 30).weightLb == 45, "the planned weight is untouched")
    }

    @Test func fixedWeightSettersKeepOrClearOrSetThePoundNumber() {
        let item = RoutineExercise(exerciseId: "b", sets: 3, reps: 5, fixedWeightKg: lb(45), fixedWeightLb: 45)
        #expect(item.with(fixedWeightKg: lb(45)).fixedWeightLb == 45)
        #expect(item.with(fixedWeightKg: 20).fixedWeightLb == nil)
        #expect(item.with(fixedWeightKg: nil).fixedWeight == nil)
        #expect(item.with(fixedWeight: PoundWeight.entered(50, unit: .lb)).fixedWeight == PoundWeight.entered(50, unit: .lb))
        let planned = RoutineExercise(exerciseId: "b", sets: 3, reps: 5, weightKg: lb(45), weightLb: 45)
        #expect(planned.with(fixedWeight: nil).weightLb == 45)
    }

    // MARK: PlanChange

    @Test func aPlanChangeKeepsAnAgreeingPoundNumberAndDropsAnotherOne() throws {
        #expect(PlanChange(id: "c", type: .weight, weightKg: lb(45), weightLb: 45).weightLb == 45)
        #expect(PlanChange(id: "c", type: .weight, weightKg: 20.3, weightLb: 45).weightLb == nil)
        #expect(PlanChange(id: "c", type: .weight, weightLb: 45).weightLb == nil, "the server fills kg; none here")
        let kept = try decode(PlanChange.self, #"{"id":"c","type":"weight","weightKg":20.41165665,"weightLb":45}"#)
        #expect(kept.weightLb == 45 && kept.type == .weight)
        let dropped = try decode(PlanChange.self, #"{"id":"c","type":"weight","weightKg":20.3,"weightLb":45}"#)
        #expect(dropped.weightLb == nil && dropped.weightKg == 20.3)
        let change = PlanChange(id: "c", type: .addExercise, routineId: "r", exerciseId: "b", sets: 3, reps: 5,
                                weightKg: lb(45), weightLb: 45, reason: "why")
        #expect(try roundTrip(change) == change)
        let json = String(decoding: try JSONEncoder().encode(change), as: UTF8.self)
        #expect(json.contains(#""weightLb":45"#), "the JSON contract's name")
    }

    @Test func aPlanChangeWithoutAPoundNumberDecodesAsBefore() throws {
        let change = try decode(PlanChange.self, """
            {"id":"c1","type":"swap-exercise","routineId":"r","exerciseId":"a","toExerciseId":"b","sets":3,
             "reps":10,"repsMin":8,"sec":30,"weightKg":20,"minutes":2,"speed":5,"incKg":2.5,"policy":"double",
             "position":1,"name":"n","weekday":2,"paused":true,"date":"2026-11-12","reason":"r"}
            """)
        #expect(change == PlanChange(id: "c1", type: .swapExercise, routineId: "r", exerciseId: "a", toExerciseId: "b",
                                     sets: 3, reps: 10, repsMin: 8, sec: 30, weightKg: 20, minutes: 2, speed: 5,
                                     incKg: 2.5, policy: .double, position: 1, name: "n", weekday: 2, paused: true,
                                     date: "2026-11-12", reason: "r"))
        #expect(change.weightLb == nil)
    }

    // MARK: SessionResult

    @Test func aSessionResultKeepsAnAgreeingPoundNumber() {
        #expect(SessionResult(date: .now, weightKg: lb(45), weightLb: 45, reps: [5]).weight == pounds45)
        #expect(SessionResult(date: .now, weightKg: 20.3, weightLb: 45, reps: [5]).weightLb == nil)
    }
}
