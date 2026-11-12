import Testing
@testable import GymCore

/// The pound number a weight keeps next to its kg (plan 38): the helpers, the formatter and the rounder.
@Suite struct PoundWeightTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }

    // MARK: Agreement

    @Test func aPoundNumberIsKeptOnlyWhenItIsThatWeight() {
        #expect(PoundWeight(kg: lb(45), lb: 45).lb == 45)
        #expect(PoundWeight(kg: 20.41, lb: 45).lb == 45, "0.0017 kg apart is the same weight")
        #expect(PoundWeight(kg: 20.3, lb: 45).lb == nil, "0.11 kg apart is another weight")
        #expect(PoundWeight(kg: 20, lb: nil).lb == nil)
        #expect(PoundWeight(kg: 20, lb: .nan).lb == nil)
        #expect(PoundWeight.agreeing(45, kg: nil) == nil, "no kg, no pound number")
        #expect(PoundWeight.agreeing(45, kg: lb(45) + 0.0099) == 45, "under 0.01 kg is still within")
        #expect(PoundWeight.agreeing(45, kg: lb(45) + 0.011) == nil)
    }

    // MARK: Entered, snapped, carried

    @Test func aNumberEnteredInPoundsKeepsIt() {
        let entered = PoundWeight.entered(47.5, unit: .lb)
        #expect(entered.kg == lb(47.5) && entered.lb == 47.5)
        let kg = PoundWeight.entered(20, unit: .kg)
        #expect(kg.kg == 20 && kg.lb == nil)
    }

    @Test func snappingGoesToTheNearestHalfPound() {
        #expect(PoundWeight.snappedToHalfPound(kg: 20.3) == PoundWeight.entered(45, unit: .lb), "44.75 lb")
        #expect(PoundWeight.snappedToHalfPound(kg: 20) == PoundWeight.entered(44, unit: .lb), "44.09 lb")
        #expect(PoundWeight.snappedToHalfPound(kg: 21.4) == PoundWeight.entered(47, unit: .lb), "47.18 lb")
        #expect(PoundWeight.snappedToHalfPound(kg: 21.5) == PoundWeight.entered(47.5, unit: .lb), "47.40 lb")
        #expect(PoundWeight.snappedToHalfPound(kg: 20.411656) == PoundWeight.entered(45, unit: .lb), "float drift")
    }

    @Test func aCarriedWeightKeepsItsPoundNumberOrSnapsInPounds() {
        let pounds = PoundWeight(kg: lb(47.5), lb: 47.5)
        #expect(pounds.carried(in: .lb) == pounds)
        #expect(pounds.carried(in: .kg) == pounds, "copying a weight copies both")
        #expect(PoundWeight(kg: 20.3, lb: nil).carried(in: .lb) == PoundWeight.entered(45, unit: .lb))
        #expect(PoundWeight(kg: 20.3, lb: nil).carried(in: .kg) == PoundWeight(kg: 20.3, lb: nil), "kg isn't snapped")
    }

    @Test func aWeightThatReplacesAnotherKeepsItsPoundNumberOnlyWhileTheKgIsTheSame() {
        let old = PoundWeight(kg: lb(45), lb: 45)
        #expect(PoundWeight.replacing(old, kg: lb(45)) == old)
        #expect(PoundWeight.replacing(old, kg: 20) == PoundWeight(kg: 20, lb: nil))
        #expect(PoundWeight.replacing(nil, kg: 20) == PoundWeight(kg: 20, lb: nil))
    }

    @Test func aListingWeightCreatedInPoundsKeepsItsWholeOrQuarterPound() {
        #expect(PoundWeight.listing(kg: lb(53)).lb == 53)
        #expect(PoundWeight.listing(kg: lb(2.25)).lb == 2.25)
        #expect(PoundWeight.listing(kg: lb(52.5)).lb == 52.5)
        #expect(PoundWeight.listing(kg: 24).lb == nil, "52.91 lb: made in kg")
        #expect(PoundWeight.listing(kg: 20).lb == nil, "44.09 lb")
        #expect(PoundWeight.listing(kg: lb(53)).kg == lb(53), "the kg stays as listed")
    }

    // MARK: Display

    @Test func poundsShowThePoundNumberAndKgShowsKg() {
        #expect(UnitConverter.fromKg(20.3, lb: 45, to: .lb) == 20.3 / UnitConverter.kgPerLb, "disagreeing: dropped")
        #expect(UnitConverter.fromKg(lb(45) - 0.004, lb: 45, to: .lb) == 45)
        #expect(UnitConverter.fromKg(20, lb: nil, to: .lb) == UnitConverter.fromKg(20, to: .lb))
        #expect(UnitConverter.fromKg(lb(45), lb: 45, to: .kg) == lb(45))
        #expect(PoundWeight(kg: lb(45) - 0.004, lb: 45).value(in: .lb) == 45)
    }

    @Test func formatterUsesThePoundNumber() {
        let kg = lb(45) - 0.004 // 44.99 lb, a pound number of 45
        #expect(WeightFormatter.number(kg: kg, lb: 45, unit: .lb) == "45")
        #expect(WeightFormatter.number(kg: kg, lb: nil, unit: .lb) == "45")
        #expect(WeightFormatter.number(kg: 20.3, lb: nil, unit: .lb) == "44.8")
        #expect(WeightFormatter.number(kg: lb(47.25), lb: 47.25, unit: .lb) == "47.3", "one decimal at most")
        #expect(WeightFormatter.number(kg: 20, lb: nil, unit: .kg) == "20")
        #expect(WeightFormatter.number(kg: lb(45), lb: 45, unit: .kg) == "20.4")
        #expect(WeightFormatter.format(kg: kg, lb: 45, unit: .lb) == "45 lb (20.4 kg)")
        #expect(WeightFormatter.format(kg: kg, lb: 45, unit: .kg) == "20.4 kg (45 lb)")
        #expect(WeightFormatter.format(kg: kg, lb: 45, unit: .lb, includeSecondary: false) == "45 lb")
    }

    // MARK: Rounder

    @Test func theRoundersPoundResultIsAPoundNumber() {
        let near = LoadRounder.barbellLb.nearestWeight(20.3)
        #expect(near.lb == 45 && near.kg == LoadRounder.barbellLb.nearest(20.3))
        let down = LoadRounder.dumbbellLb.downWeight(lb(49))
        #expect(down.lb == 47.5 && down.kg == LoadRounder.dumbbellLb.down(lb(49)))
        let offset = LoadRounder(unit: .lb, step: 10, offset: 5).nearestWeight(lb(52))
        #expect(offset.lb == 55)
    }

    @Test func theRoundersKgResultHasNoPoundNumber() {
        let near = LoadRounder.barbellKg.nearestWeight(lb(45))
        #expect(near == PoundWeight(kg: 20, lb: nil))
        #expect(LoadRounder.barbellKg.downWeight(21) == PoundWeight(kg: 20, lb: nil))
        #expect(LoadRounder(unit: .lb, step: 0).nearestWeight(20.3) == PoundWeight(kg: 20.3, lb: nil), "no grid")
    }
}
