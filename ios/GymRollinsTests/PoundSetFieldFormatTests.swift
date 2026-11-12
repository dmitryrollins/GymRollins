import Foundation
import GymCore
import Testing
@testable import GymRollins

/// The weight box keeps the pound number (plan 38): typing in lb sets it, the box shows it, and copying a weight to
/// another set copies both.
@Suite struct PoundSetFieldFormatTests {
    private let id = UUID()
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    /// 47.25 lb stored a little under its kg: converted from kg it shows "47.2", by its pound number "47.3".
    private let quarter = PoundWeight(kg: UnitConverter.toKg(47.25, from: .lb) - 0.009, lb: 47.25)

    @Test func typingInPoundsSetsThePoundNumber() throws {
        let set = WorkoutSet(id: id, weightKg: 60, reps: 8)
        let typed = try #require(SetFieldFormat.applying("47.5", to: .weight(id), set: set, unit: .lb))
        #expect(typed.weightKg == lb(47.5) && typed.weightLb == 47.5)
        #expect(SetFieldFormat.applying("47,5", to: .weight(id), set: set, unit: .lb)?.weightLb == 47.5)
        #expect(typed.reps == 8 && typed.id == id)
    }

    @Test func typingInKgClearsThePoundNumber() throws {
        let set = WorkoutSet(id: id, weightKg: lb(45), weightLb: 45, reps: 8)
        let typed = try #require(SetFieldFormat.applying("22.5", to: .weight(id), set: set, unit: .kg))
        #expect(typed.weight == PoundWeight(kg: 22.5, lb: nil))
    }

    @Test func theBoxShowsThePoundNumber() {
        let set = WorkoutSet(id: id, weightKg: quarter.kg, weightLb: quarter.lb, reps: 8)
        #expect(SetFieldFormat.display(.weight(id), set: set, unit: .lb) == "47.3")
        #expect(SetFieldFormat.display(.weight(id), set: WorkoutSet(id: id, weightKg: quarter.kg, reps: 8), unit: .lb)
            == "47.2", "no pound number: converted from kg")
        #expect(SetFieldFormat.display(.weight(id), set: set, unit: .kg) == "21.4")
    }

    @Test func leavingTheShownNumberKeepsTheWeight() {
        let set = WorkoutSet(id: id, weightKg: quarter.kg, weightLb: quarter.lb, reps: 8)
        #expect(SetFieldFormat.applying("47.3", to: .weight(id), set: set, unit: .lb) == set)
    }

    @Test func editingRepsKeepsThePoundNumber() {
        let set = WorkoutSet(id: id, weightKg: lb(47.5), weightLb: 47.5, reps: 8)
        #expect(SetFieldFormat.applying("10", to: .reps(id), set: set, unit: .lb)?.weight == set.weight)
    }

    @Test func copyingAWeightCopiesItsPoundNumber() {
        let source = WorkoutSet(weightKg: lb(47.5), weightLb: 47.5, reps: 10)
        let target = WorkoutSet(weightKg: 20, reps: 8)
        let copied = SetFieldFormat.copying(.weight(source.id), from: source, to: target)
        #expect(copied.weight == source.weight && copied.reps == 8 && copied.id == target.id)
        let plain = SetFieldFormat.copying(.weight(source.id), from: WorkoutSet(weightKg: 30, reps: 5), to: copied)
        #expect(plain.weight == PoundWeight(kg: 30, lb: nil), "a kg weight leaves no pound number behind")
        let reps = SetFieldFormat.copying(.reps(source.id), from: WorkoutSet(weightKg: 30, reps: 5), to: copied)
        #expect(reps.weight == source.weight && reps.reps == 5)
    }
}
