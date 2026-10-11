import Testing
@testable import GymCore

@Suite struct PlateCalculatorTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }

    @Test func ownersBenchLoad() {
        let load = PlateCalculator.load(targetKg: lb(140), inventory: .standardLb)
        #expect(load.perSide == [45, 2.5])
        #expect(load.total == 140)
        #expect(load.remainder == 0)
    }

    @Test func exactPlates() {
        #expect(PlateCalculator.load(targetKg: lb(135), inventory: .standardLb).perSide == [45])
        #expect(PlateCalculator.load(targetKg: lb(225), inventory: .standardLb).perSide == [45, 45])
    }

    @Test func barOnly() {
        let load = PlateCalculator.load(targetKg: lb(45), inventory: .standardLb)
        #expect(load.perSide.isEmpty)
        #expect(load.total == 45)
    }

    @Test func belowBarGivesBar() {
        let load = PlateCalculator.load(targetKg: lb(30), inventory: .standardLb)
        #expect(load.perSide.isEmpty)
        #expect(load.total == 45)
        #expect(load.remainder == 0)
    }

    @Test func unreachableRemainder() {
        let load = PlateCalculator.load(targetKg: lb(142), inventory: .standardLb)
        #expect(load.perSide == [45, 2.5])
        #expect(load.remainder == 2)
    }

    @Test func kilogramInventory() {
        #expect(PlateCalculator.load(targetKg: 100, inventory: .standardKg).perSide == [25, 15])
    }

    @Test func negligiblePlateIsIgnoredWithoutCrashing() {
        let inventory = PlateInventory(unit: .lb, bar: 45, plates: [45, 0.001])
        let load = PlateCalculator.load(targetKg: lb(140), inventory: inventory)
        #expect(load.perSide == [45])
        #expect(load.total == 135)
        #expect(load.remainder == 5)
    }

    @Test func emptyPlatesListGivesBarOnlyWithRemainder() {
        let inventory = PlateInventory(unit: .lb, bar: 45, plates: [])
        let load = PlateCalculator.load(targetKg: lb(200), inventory: inventory)
        #expect(load.perSide.isEmpty)
        #expect(load.total == 45)
        #expect(load.remainder == 155)
    }

    @Test func exactCombinationBeatsGreedyRemainder() {
        // Greedy from [25, 20] per side would take one 25 (leaving 5 kg unfilled: no 20 fits).
        // The exact combination [20, 20] per side hits 100 kg exactly.
        let inventory = PlateInventory(unit: .kg, bar: 20, plates: [25, 20])
        let load = PlateCalculator.load(targetKg: 100, inventory: inventory)
        #expect(load.perSide == [20, 20])
        #expect(load.total == 100)
        #expect(load.remainder == 0)
    }

    @Test func exactSearchTieBreaksByFewestPlatesThenHeaviestFirst() {
        // Per side target 50 kg with plates [25, 20, 10, 5]: 25+25 (2 plates) beats 20+20+10 (3 plates).
        let inventory = PlateInventory(unit: .kg, bar: 20, plates: [25, 20, 10, 5])
        let load = PlateCalculator.load(targetKg: 120, inventory: inventory)
        #expect(load.perSide == [25, 25])
        #expect(load.total == 120)
        #expect(load.remainder == 0)
    }

    @Test func hugeTargetFallsBackToGreedyWithoutHanging() {
        let inventory = PlateInventory(unit: .lb, bar: 45, plates: [45, 35, 25, 10, 5, 2.5])
        let load = PlateCalculator.load(targetKg: lb(5_000), inventory: inventory)
        #expect(load.perSide.first == 45)
        #expect(load.total <= 5_000)
    }
}
