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
        #expect(editing.options.first { $0.label == "44 lb (20 kg)" } != nil)
        #expect(editing.options.first { $0.label == "53 lb (24 kg)" } != nil)
        let metric = ListingLoadsEditing(kind: kettlebells, unit: .kg, loads: .none)
        #expect(metric.options.first { $0.kg == 20 }?.label == "20 kg")
    }

    /// The chip reading 53 lb stores 53 lb, so what the gym holds and what history logs for that bell agree.
    @Test func anLbUsersKettlebellChipStoresTheLabelsOwnWeight() throws {
        let lb = ListingLoadsEditing(kind: kettlebells, unit: .lb, loads: .none)
        let chip = try #require(lb.options.first { $0.label == "53 lb (24 kg)" })
        #expect(abs(chip.kg - UnitConverter.toKg(53, from: .lb)) < 1e-9)
        let metric = ListingLoadsEditing(kind: kettlebells, unit: .kg, loads: .none)
        #expect(try #require(metric.options.first { $0.label == "24 kg" }).kg == 24)
    }

    /// UI tests and VoiceOver users find a chip by its nominal kilograms, whatever unit it stores.
    @Test func aChipKeepsItsNominalTag() throws {
        let lb = ListingLoadsEditing(kind: kettlebells, unit: .lb, loads: .none)
        #expect(lb.options.map(\.tag) == [4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 28, 32, 40])
        let metric = ListingLoadsEditing(kind: kettlebells, unit: .kg, loads: .none)
        #expect(metric.options.map(\.tag) == metric.options.map(\.kg))
        let odd = ListingLoadsEditing(kind: kettlebells, unit: .lb, loads: .fixed(kg: [15]))
        #expect(odd.options.first { $0.kg == 15 }?.tag == 15)
    }

    @Test func aChipIsSelectedByEitherSpellingOfTheBell() throws {
        let lb = ListingLoadsEditing(kind: kettlebells, unit: .lb, loads: .fixed(kg: [24]))
        let chip = try #require(lb.options.first { $0.label == "53 lb (24 kg)" })
        #expect(lb.isSelected(chip.kg), "a bell saved as 24 kg still shows as selected")
        #expect(lb.options.count == ListingLoadsEditing(kind: kettlebells, unit: .lb, loads: .none).options.count,
                "and isn't offered twice")
        let saved = ListingLoadsEditing(kind: kettlebells, unit: .kg, loads: .fixed(kg: [UnitConverter.toKg(53, from: .lb)]))
        #expect(saved.isSelected(24))
    }

    private static let nominalBells: [Double] = [4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 28, 32, 40]

    /// A bell saved by a chip, or as its nominal kilograms, or by a unit switch, is the same bell: one chip, selected.
    @Test func everyUsualBellIsOneSelectedChipWhicheverWayItWasStored() throws {
        for unit in [WeightUnit.lb, .kg] {
            for nominal in Self.nominalBells {
                let wholeLb = UnitConverter.fromKg(nominal, to: .lb).rounded()
                let tenthLb = (UnitConverter.fromKg(nominal, to: .lb) * 10).rounded() / 10
                let chipLb = UnitConverter.toKg(nominal * 2.2046226 >= 10 ? wholeLb : tenthLb, from: .lb)
                for stored in [nominal, chipLb] {
                    let editing = ListingLoadsEditing(kind: kettlebells, unit: unit, loads: .fixed(kg: [stored]))
                    let note = "\(nominal) kg stored as \(stored), shown in \(unit)"
                    #expect(editing.options.map(\.tag) == Self.nominalBells, "one chip per bell: \(note)")
                    let chip = try #require(editing.options.first { $0.tag == nominal }, "\(note)")
                    #expect(editing.isSelected(chip.kg), "selected: \(note)")
                    #expect(chip.label.contains("(\(Int(nominal)) kg)") || unit == .kg, "bracket is nominal: \(chip.label)")
                    let toggledOff = editing.toggled(chip.kg)
                    #expect(toggledOff == .fixed(kg: []), "tapping the selected chip clears it: \(note)")
                }
            }
        }
    }

    @Test func aSixteenKiloBellReadsAsTheNominalBracket() throws {
        let lb = ListingLoadsEditing(kind: kettlebells, unit: .lb, loads: .none)
        #expect(lb.options.first { $0.tag == 16 }?.label == "35 lb (16 kg)")
        #expect(lb.options.first { $0.tag == 12 }?.label == "26 lb (12 kg)")
        let saved = ListingLoadsEditing(kind: kettlebells, unit: .lb, loads: .fixed(kg: [16]))
        #expect(saved.options.filter { $0.tag == 16 }.count == 1)
        #expect(saved.options.first { $0.tag == 16 }?.label == "35 lb (16 kg)")
        let every = ListingLoadsEditing(kind: kettlebells, unit: .lb, loads: lb.togglingAll())
        #expect(every.allSelected)
        let mixed = ListingLoadsEditing(kind: kettlebells, unit: .lb, loads: .fixed(kg: [15.876]))
        #expect(mixed.options.filter { $0.tag == 16 }.count == 1)
        let kg = ListingLoadsEditing(kind: kettlebells, unit: .kg, loads: .fixed(kg: [15.876]))
        #expect(kg.options.filter { $0.label == "16 kg" }.count == 1)
        #expect(kg.options.count == Self.nominalBells.count)
    }

    @Test func aBellTheUserTypedKeepsItsRealValue() throws {
        let editing = ListingLoadsEditing(kind: kettlebells, unit: .lb, loads: .fixed(kg: [15.5]))
        let odd = try #require(editing.options.first { $0.kg == 15.5 })
        #expect(odd.label == "34 lb (15.5 kg)")
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
