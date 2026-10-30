import Foundation
import GymCore

/// What a listing's loads control offers for one kind of equipment, in the user's unit (spec §5, step 4): a stepper
/// for a weight stack's top, chips for a fixed set, nothing for plates and bodyweight. Everything is stored in kg.
struct ListingLoadsEditing: Equatable {
    /// One chip of a fixed set: the weight it stores and how it reads.
    struct Option: Equatable, Identifiable {
        let kg: Double
        let label: String
        var id: Double { kg }
    }

    static let maxStackKg = 1000.0
    private static let tolerance = 0.01
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

    /// One step up or down, landing on a multiple of the step; never below one step or above 1000 kg.
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
        let usual = kind.id == "kettlebells" ? Self.kettlebellKg : dumbbellKg
        let extra = selectedKg.filter { chosen in !usual.contains { Self.same($0, chosen) } }
        return (usual + extra).sorted().map { Option(kg: $0, label: label(for: $0)) }
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

    /// 5 to 100 lb by 5, or 2 to 50 kg by 2.
    private var dumbbellKg: [Double] {
        unit == .lb ? stride(from: 5.0, through: 100, by: 5).map { UnitConverter.toKg($0, from: .lb) }
            : stride(from: 2.0, through: 50, by: 2).map { $0 }
    }

    /// "44 lb (20 kg)" for kettlebells to an lb user, "20 kg", "25 lb".
    private func label(for kg: Double) -> String {
        let converted = UnitConverter.fromKg(kg, to: unit)
        let value = converted >= 10 ? String(Int(converted.rounded())) : WeightFormatter.number(converted)
        guard unit == .lb, kind.id == "kettlebells" else { return "\(value) \(unit.rawValue)" }
        return "\(value) lb (\(WeightFormatter.number(kg)) kg)"
    }

    private static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < tolerance }
}
