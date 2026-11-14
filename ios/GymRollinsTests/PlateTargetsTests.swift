import Foundation
import GymCore
import Testing
@testable import GymRollins

/// The plate calculator opens on the set the owner is on (a warm-up at the bar is "bar only", not the working weight)
/// and offers the exercise's other weights, one per run of neighbouring sets of the same kind and weight.
@Suite struct PlateTargetsTests {
    private func lb(_ pounds: Double) -> Double { pounds * UnitConverter.kgPerLb }
    private func warmup(_ pounds: Double, done: Bool = false) -> WorkoutSet {
        WorkoutSet(weightKg: lb(pounds), reps: 5, done: done, warmup: true)
    }
    private func working(_ pounds: Double, done: Bool = false) -> WorkoutSet {
        WorkoutSet(weightKg: lb(pounds), reps: 8, done: done)
    }

    private func summary(_ targets: [PlateTarget]) -> [String] {
        targets.map { "\($0.id) \($0.title) \(WeightFormatter.number(UnitConverter.fromKg($0.weightKg, to: .lb)))" }
    }

    @Test func neighbouringSetsOfOneKindAndWeightShareATarget() {
        let sets = [warmup(45), warmup(75), working(100), working(100), working(100)]
        #expect(summary(PlateTargets.targets(for: sets))
            == ["warmup.1 Warm-up 1 45", "warmup.2 Warm-up 2 75", "working.1 Sets 1–3 100"])
        #expect(PlateTargets.targets(for: sets).last?.setIds == sets.suffix(3).map(\.id))
    }

    @Test func aChangeOfWeightOrKindStartsANewTarget() {
        let sets = [warmup(45), warmup(45), warmup(100), working(100), working(105), working(105), working(100)]
        #expect(summary(PlateTargets.targets(for: sets)) == [
            "warmup.1 Warm-ups 1–2 45", "warmup.3 Warm-up 3 100", "working.1 Set 1 100", "working.2 Sets 2–3 105",
            "working.4 Set 4 100",
        ])
    }

    @Test func opensOnTheFirstSetNotDone() {
        let planned = [warmup(45), warmup(75), working(100), working(100)]
        #expect(PlateTargets.current(in: PlateTargets.targets(for: planned), sets: planned, editing: nil)?.id
            == "warmup.1")
        let underway = [warmup(45, done: true), warmup(75), working(100), working(100)]
        #expect(PlateTargets.current(in: PlateTargets.targets(for: underway), sets: underway, editing: nil)?.id
            == "warmup.2")
        let onWorking = [warmup(45, done: true), warmup(75, done: true), working(100, done: true), working(100)]
        #expect(PlateTargets.current(in: PlateTargets.targets(for: onWorking), sets: onWorking, editing: nil)?.id
            == "working.1")
    }

    @Test func theBoxBeingTypedInWins() {
        let sets = [warmup(45), warmup(75), working(100), working(105)]
        let targets = PlateTargets.targets(for: sets)
        #expect(PlateTargets.current(in: targets, sets: sets, editing: sets[3].id)?.id == "working.2")
        #expect(PlateTargets.current(in: targets, sets: sets, editing: UUID())?.id == "warmup.1")
    }

    @Test func everySetDoneOpensOnTheLast() {
        let sets = [warmup(45, done: true), working(100, done: true), working(110, done: true)]
        #expect(PlateTargets.current(in: PlateTargets.targets(for: sets), sets: sets, editing: nil)?.id == "working.2")
    }

    @Test func noSetsNoTargets() {
        #expect(PlateTargets.targets(for: []).isEmpty)
        #expect(PlateTargets.current(in: [], sets: [], editing: nil) == nil)
    }

    @Test(arguments: [(45.0, PlateColor.blue), (35, .yellow), (25, .green), (10, .white), (5, .grey), (2.5, .silver)])
    func poundPlatesTakeTheColorOfTheirKilogramTwin(_ plate: Double, _ color: PlateColor) {
        #expect(PlateColor.of(plate, unit: .lb) == color)
    }

    @Test(arguments: [(25.0, PlateColor.red), (20, .blue), (15, .yellow), (10, .green), (5, .white), (2.5, .grey),
                      (1.25, .silver), (0.5, .silver)])
    func kilogramPlatesTakeTheirStandardColor(_ plate: Double, _ color: PlateColor) {
        #expect(PlateColor.of(plate, unit: .kg) == color)
    }
}
