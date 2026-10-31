import Foundation
import GymCore

/// What a listing's loads control offers for one kind of equipment, in the user's unit (spec §5, step 4): a stepper
/// for a weight stack's top, chips for a fixed set, nothing for plates and bodyweight. Everything is stored in kg.
struct ListingLoadsEditing: Equatable {
    /// One chip of a fixed set: the weight it stores and how it reads. `tag` is the kg the chip is named by (its
    /// accessibility identifier), which stays "16" for the 35 lb chip whose stored weight is 15.88 kg.
    struct Option: Equatable, Identifiable {
        let kg: Double
        let label: String
        let tag: Double
        var id: Double { kg }
    }

    static let maxStackKg = DomainLimits.listingStackKg.upperBound
    /// A chip counts as selected for either spelling of its bell: 53 lb (24.04 kg) or 24 kg, 35 lb (15.88 kg) or
    /// 16 kg. The same slack the gym's loads are fitted with, so the chips and the fitting agree.
    private static let tolerance = AvailableLoads.toleranceKg
    private static let kettlebellKg: [Double] = [4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 28, 32, 40]

    let kind: EquipmentKind
    let unit: WeightUnit
    private(set) var loads: ListingLoads

    /// The loads are made to fit the kind: a stack for a stack kind (250 lb or 110 kg when there is none yet), no
    /// weights chosen for a fixed set, plates for plate-loaded kinds, nothing for the rest.
    init(kind: EquipmentKind, unit: WeightUnit, loads: ListingLoads) {
        self.kind = kind
        self.unit = unit
        switch (kind.load, loads) {
        case (.stack, .stack): self.loads = loads
        case (.stack, _): self.loads = .stack(maxKg: Self.defaultStackKg(unit), stepKg: nil)
        case (.fixedSet, .fixed): self.loads = loads
        case (.fixedSet, _): self.loads = .fixed(kg: [])
        case (.plateLoaded, _): self.loads = .plates
        case (.bodyweight, _), (.none, _): self.loads = ListingLoads.none
        }
    }

    static func defaultStackKg(_ unit: WeightUnit) -> Double { unit == .lb ? UnitConverter.toKg(250, from: .lb) : 110 }

    /// Nothing to enter: Save is always allowed.
    var hasInput: Bool { kind.load == .stack || kind.load == .fixedSet }

    /// A fixed set needs at least one weight.
    var isValid: Bool {
        if case let .fixed(kg) = loads { return !kg.isEmpty }
        return true
    }

    // MARK: Stack

    /// 5 lb or 2.5 kg.
    var stepInUnit: Double { unit == .lb ? 5 : 2.5 }
    var stackKg: Double? { if case let .stack(maxKg, _) = loads { maxKg } else { nil } }

    /// "250 lb (113 kg)".
    var stackText: String? { stackKg.map { WeightFormatter.format(kg: $0, unit: unit) } }

    var canDecrement: Bool { stackKg.map { nextStack($0, direction: -1) != nil } ?? false }
    var canIncrement: Bool { stackKg.map { nextStack($0, direction: 1) != nil } ?? false }

    /// One step up or down, landing on a multiple of the step; never below one step or above the top of the allowed range.
    func steppedStack(_ direction: Int) -> ListingLoads {
        guard case let .stack(maxKg, step) = loads, let next = nextStack(maxKg, direction: direction) else { return loads }
        return .stack(maxKg: next, stepKg: step)
    }

    private func nextStack(_ kg: Double, direction: Int) -> Double? {
        let value = UnitConverter.fromKg(kg, to: unit) / stepInUnit
        let target = direction > 0 ? (value + 1e-6).rounded(.down) + 1 : (value - 1e-6).rounded(.up) - 1
        guard target >= 1 else { return nil }
        let next = UnitConverter.toKg(target * stepInUnit, from: unit)
        return next <= Self.maxStackKg ? next : nil
    }

    // MARK: Fixed set

    /// The chips: the kind's usual weights plus any the listing already has that are not among them.
    var options: [Option] {
        let usual = kind.id == "kettlebells" ? kettlebellChips : dumbbellKg.map { (kg: $0, tag: $0) }
        let extra = selectedKg.filter { chosen in !usual.contains { Self.same($0.kg, chosen) } }
        let usualOptions = usual.map { Option(kg: $0.kg, label: label(for: $0.kg, nominalKg: $0.tag), tag: $0.tag) }
        let extraOptions = extra.map { Option(kg: $0, label: label(for: $0, nominalKg: $0), tag: $0) }
        return (usualOptions + extraOptions).sorted { $0.kg < $1.kg }
    }

    var selectedKg: [Double] { if case let .fixed(kg) = loads { kg } else { [] } }

    func isSelected(_ kg: Double) -> Bool { selectedKg.contains { Self.same($0, kg) } }

    var allSelected: Bool { hasInput && !options.isEmpty && options.allSatisfy { isSelected($0.kg) } }

    func toggled(_ kg: Double) -> ListingLoads {
        let kept = selectedKg.filter { !Self.same($0, kg) }
        return .fixed(kg: (isSelected(kg) ? kept : kept + [kg]).sorted())
    }

    /// Every chip on, or all off when they already are.
    func togglingAll() -> ListingLoads { allSelected ? .fixed(kg: []) : .fixed(kg: options.map(\.kg)) }

    /// The usual bells. An lb user's chip reads in pounds ("53 lb (24 kg)"), so it stores that label's own weight.
    private var kettlebellChips: [(kg: Double, tag: Double)] {
        Self.kettlebellKg.map { nominal in
            (kg: unit == .lb ? UnitConverter.toKg(Self.labelledLb(nominal), from: .lb) : nominal, tag: nominal)
        }
    }

    /// The pounds a chip's label shows: whole from 10 lb up, else one decimal.
    private static func labelledLb(_ kg: Double) -> Double {
        let lb = UnitConverter.fromKg(kg, to: .lb)
        return lb >= 10 ? lb.rounded() : (lb * 10).rounded() / 10
    }

    /// 5 to 100 lb by 5, or 2 to 50 kg by 2.
    private var dumbbellKg: [Double] {
        unit == .lb ? stride(from: 5.0, through: 100, by: 5).map { UnitConverter.toKg($0, from: .lb) }
            : stride(from: 2.0, through: 50, by: 2).map { $0 }
    }

    /// "44 lb (20 kg)" for kettlebells to an lb user, "20 kg", "25 lb". A usual bell is named by its nominal kilograms
    /// (35 lb is "16 kg", not the 15.9 its pounds convert to); a weight the user typed shows what it is.
    private func label(for kg: Double, nominalKg: Double) -> String {
        let converted = UnitConverter.fromKg(kg, to: unit)
        let value = converted >= 10 ? String(Int(converted.rounded())) : WeightFormatter.number(converted)
        guard unit == .lb, kind.id == "kettlebells" else { return "\(value) \(unit.rawValue)" }
        return "\(value) lb (\(WeightFormatter.number(nominalKg)) kg)"
    }

    private static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < tolerance }
}
