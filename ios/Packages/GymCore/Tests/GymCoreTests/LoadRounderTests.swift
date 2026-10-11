import Testing
@testable import GymCore

@Suite struct LoadRounderTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private func inLb(_ kg: Double) -> Double { (UnitConverter.fromKg(kg, to: .lb) * 1000).rounded() / 1000 }

    // MARK: From the plate inventory (Codex P2)

    @Test func inventoryWithoutSmallPlatesMovesInTenPoundSteps() {
        let noTwoAndHalf = PlateInventory(unit: .lb, bar: 45, plates: [45, 35, 25, 10, 5])
        let rounder = LoadRounder.barbell(inventory: noTwoAndHalf)
        #expect(inLb(rounder.nearest(lb(135 + 5))) == 145)   // 140 isn't loadable with 5 lb the smallest plate
        #expect(inLb(rounder.nearest(lb(138))) == 135)
        #expect(inLb(rounder.down(lb(144))) == 135)
    }

    @Test func standardInventoriesMatchTheFixedRounders() {
        #expect(LoadRounder.barbell(inventory: .standardLb) == .barbellLb)
        #expect(LoadRounder.barbell(inventory: .standardKg) == .barbellKg)
        #expect(LoadRounder.barbell(inventory: PlateInventory(unit: .lb, bar: 45, plates: [])) == .barbellLb)
    }

    /// Every total the rounder can suggest (from the bar up) is exactly loadable with the inventory.
    @Test func everySuggestedTotalIsLoadable() {
        let inventories = [
            PlateInventory(unit: .lb, bar: 45, plates: [45, 35, 25, 10, 5]),
            PlateInventory(unit: .lb, bar: 35, plates: [45, 25, 10]),
            PlateInventory(unit: .kg, bar: 20, plates: [20, 10, 5, 2.5]),
            PlateInventory(unit: .kg, bar: 15, plates: [25, 1.25]),
        ]
        for inv in inventories {
            let rounder = LoadRounder.barbell(inventory: inv)
            var target = inv.bar
            while target < inv.bar + 200 {
                let kg = rounder.nearest(UnitConverter.toKg(target, from: inv.unit))
                let load = PlateCalculator.load(targetKg: kg, inventory: inv)
                #expect(load.remainder == 0, "\(inv) \(target) -> \(load.total)")
                target += 1.25
            }
        }
    }

    @Test func nearestBarbellStep() {
        #expect(inLb(LoadRounder.barbellLb.nearest(lb(133))) == 135)
        #expect(inLb(LoadRounder.barbellLb.nearest(lb(132))) == 130)
    }

    @Test func downIsStableForExactValues() {
        // 140 lb round-trips through kg without dropping to 135
        #expect(inLb(LoadRounder.barbellLb.down(lb(140))) == 140)
        #expect(inLb(LoadRounder.barbellLb.down(lb(66.5))) == 65)
    }

    @Test func dumbbellStep() {
        #expect(inLb(LoadRounder.dumbbellLb.nearest(lb(26.4))) == 27.5)
    }

    @Test func kilogramStep() {
        #expect(LoadRounder.barbellKg.down(61.2) == 60)
    }

    @Test func exactTieRoundsUpToNextStep() {
        #expect(inLb(LoadRounder.barbellLb.nearest(lb(37.5))) == 40)
        #expect(inLb(LoadRounder.barbellLb.nearest(lb(197.5))) == 200)
        #expect(inLb(LoadRounder.barbellLb.nearest(lb(347.5))) == 350)
        #expect(inLb(LoadRounder.barbellLb.nearest(lb(467.5))) == 470)
    }

    @Test func everyFivePoundTieRoundsUp() {
        var tie = 2.5
        while tie <= 497.5 {
            let expected = tie + 2.5
            #expect(inLb(LoadRounder.barbellLb.nearest(lb(tie))) == expected, "tie at \(tie)")
            tie += 5
        }
    }

    @Test func nonPositiveStepReturnsInputUnchanged() {
        let rounder = LoadRounder(unit: .lb, step: 0)
        #expect(rounder.nearest(lb(133)) == lb(133))
        #expect(rounder.down(lb(133)) == lb(133))
        let negative = LoadRounder(unit: .lb, step: -5)
        #expect(negative.nearest(lb(133)) == lb(133))
    }
}
