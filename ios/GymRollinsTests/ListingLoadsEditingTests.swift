import GymCore
import Testing
@testable import GymRollins

@Suite struct ListingLoadsEditingTests {
    private let stackKind = EquipmentKind(id: "lat-pulldown", name: "Lat pulldown", category: .cable, load: .stack)
    private let kettlebells = EquipmentKind(id: "kettlebells", name: "Kettlebells", category: .freeWeight, load: .fixedSet)
    private let dumbbells = EquipmentKind(id: "dumbbells", name: "Dumbbells", category: .freeWeight, load: .fixedSet)

    @Test func aStackDefaultsAndStepsInTheUserUnit() {
        let lb = ListingLoadsEditing(kind: stackKind, unit: .lb, loads: .none)
        #expect(lb.stackText == "250 lb (113.4 kg)")
        #expect(lb.steppedStack(1).stackKgRounded(.lb) == 255)
        #expect(lb.steppedStack(-1).stackKgRounded(.lb) == 245)
        let kg = ListingLoadsEditing(kind: stackKind, unit: .kg, loads: .none)
        #expect(kg.stackText == "110 kg (242.5 lb)")
        #expect(kg.steppedStack(1).stackKgRounded(.kg) == 112.5)
    }

    @Test func aStackCantGoBelowOneStepOrAbove1000Kg() {
        var low = ListingLoadsEditing(kind: stackKind, unit: .kg, loads: .stack(maxKg: 2.5, stepKg: nil))
        #expect(!low.canDecrement)
        #expect(low.steppedStack(-1) == low.loads)
        low = ListingLoadsEditing(kind: stackKind, unit: .kg, loads: .stack(maxKg: 1000, stepKg: nil))
        #expect(!low.canIncrement)
        #expect(low.canDecrement)
    }

    @Test func steppingSnapsAnOffGridTopToTheGrid() {
        let editing = ListingLoadsEditing(kind: stackKind, unit: .lb, loads: .stack(maxKg: 80, stepKg: 4))
        #expect(editing.steppedStack(1).stackKgRounded(.lb) == 180)
        #expect(editing.steppedStack(-1).stackKgRounded(.lb) == 175)
        if case let .stack(_, step) = editing.steppedStack(1) { #expect(step == 4, "the listing's own step is kept") }
    }

    @Test func otherLoadTypesCoerce() {
        let plates = EquipmentKind(id: "barbell", name: "Barbell", category: .freeWeight, load: .plateLoaded)
        let bench = EquipmentKind(id: "flat-bench", name: "Bench", category: .bench, load: .none)
        #expect(ListingLoadsEditing(kind: plates, unit: .lb, loads: .none).loads == .plates)
        #expect(ListingLoadsEditing(kind: bench, unit: .lb, loads: .plates).loads == .none)
        #expect(!ListingLoadsEditing(kind: bench, unit: .lb, loads: .none).hasInput)
    }

    @Test func fixedSetNeedsAWeightAndKeepsWhatIsThere() {
        let empty = ListingLoadsEditing(kind: kettlebells, unit: .lb, loads: .none)
        #expect(!empty.isValid)
        let on = ListingLoadsEditing(kind: kettlebells, unit: .lb, loads: empty.toggled(20))
        #expect(on.isValid)
        #expect(on.isSelected(20))
        #expect(on.toggled(20) == .fixed(kg: []))
        #expect(ListingLoadsEditing(kind: kettlebells, unit: .lb, loads: .fixed(kg: [20, 24])).selectedKg == [20, 24])
    }

    @Test func kettlebellChipsShowBothUnitsForAnLbUser() {
        let editing = ListingLoadsEditing(kind: kettlebells, unit: .lb, loads: .none)
        #expect(editing.options.first { $0.kg == 20 }?.label == "44 lb (20 kg)")
        #expect(editing.options.first { $0.kg == 24 }?.label == "53 lb (24 kg)")
        let metric = ListingLoadsEditing(kind: kettlebells, unit: .kg, loads: .none)
        #expect(metric.options.first { $0.kg == 20 }?.label == "20 kg")
    }

    @Test func dumbbellChipsRunFiveToHundredLbOrTwoToFiftyKg() {
        let lb = ListingLoadsEditing(kind: dumbbells, unit: .lb, loads: .none).options
        #expect(lb.count == 20)
        #expect(lb.first?.label == "5 lb")
        #expect(lb.last?.label == "100 lb")
        let kg = ListingLoadsEditing(kind: dumbbells, unit: .kg, loads: .none).options
        #expect(kg.count == 25)
        #expect(kg.first?.label == "2 kg")
        #expect(kg.last?.label == "50 kg")
    }

    @Test func allSelectsEveryChipAndAnOddWeightStaysOffered() {
        let editing = ListingLoadsEditing(kind: dumbbells, unit: .kg, loads: .none)
        let all = ListingLoadsEditing(kind: dumbbells, unit: .kg, loads: editing.togglingAll())
        #expect(all.allSelected)
        #expect(all.selectedKg.count == 25)
        #expect(all.togglingAll() == .fixed(kg: []))
        let odd = ListingLoadsEditing(kind: dumbbells, unit: .kg, loads: .fixed(kg: [3]))
        #expect(odd.options.contains { $0.kg == 3 }, "a stored weight isn't lost from the chips")
    }
}

private extension ListingLoads {
    func stackKgRounded(_ unit: WeightUnit) -> Double? {
        guard case let .stack(maxKg, _) = self else { return nil }
        return (UnitConverter.fromKg(maxKg, to: unit) * 10).rounded() / 10
    }
}
