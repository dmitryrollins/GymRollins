import GymCore
import SwiftUI

/// Plate math for one of the exercise's weights. It opens on the set the owner is on (`PlateTargets.current`), and a
/// row of the exercise's other weights switches to them. Below: the weight in the profile unit, one side of the bar
/// with each plate's number written on it, in its size's color (`PlateColor`), and a "load each side" list.
struct PlatesSheet: View {
    let targets: [PlateTarget]
    @State private var selectedId: PlateTarget.ID?
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    init(targets: [PlateTarget], current: PlateTarget.ID?) {
        self.targets = targets
        _selectedId = State(initialValue: current)
    }

    /// The picked weight; the first when the pick is gone (its sets changed behind the sheet).
    private var selected: PlateTarget? { targets.first { $0.id == selectedId } ?? targets.first }
    private var weightKg: Double { selected?.weightKg ?? 0 }
    private var unit: WeightUnit { env.profile.unit }
    private var other: WeightUnit { unit == .kg ? .lb : .kg }
    private var inventoryUnit: WeightUnit { env.profile.plateInventory.unit }
    private var load: PlateLoad { PlateCalculator.load(targetKg: weightKg, inventory: env.profile.plateInventory) }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack {
                    DisplayTitle(text: "Plate Calculator", size: 28)
                    Spacer()
                    GlassPillButton(title: "Done", identifier: "plates.done") { dismiss() }
                }
                if targets.count > 1 { targetRow }
                VStack(spacing: 8) {
                    weightHeader
                    barbell
                    Divider().overlay(Theme.divider)
                    loadList
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
            }
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.medium, .large])
    }

    // MARK: Weights

    /// Wraps rather than scrolls, so every weight stays on screen.
    private var targetRow: some View {
        FlowLayout(spacing: 8) {
            ForEach(targets) { target in
                let isSelected = target.id == selected?.id
                Button { selectedId = target.id } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                        Text("\(number(target.weightKg, in: unit)) \(unit.rawValue)")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(isSelected ? Theme.primaryFill : Theme.card, in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("plates.target.\(target.id)")
            }
        }
    }

    private var weightHeader: some View {
        VStack(spacing: 2) {
            Text("\(number(weightKg, in: unit)) \(unit.rawValue)")
                .font(Theme.display(44))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityIdentifier("plates.weight")
            Text("\(number(weightKg, in: other)) \(other.rawValue) \u{00B7} " +
                 "\(WeightFormatter.number(env.profile.plateInventory.bar)) \(inventoryUnit.rawValue) bar")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func number(_ kg: Double, in unit: WeightUnit) -> String {
        WeightFormatter.number(UnitConverter.fromKg(kg, to: unit))
    }

    // MARK: Bar

    private static let steel = Color(hex: 0x55555F)
    private static let plateSpacing: CGFloat = 2

    /// One side of the bar: the grip's end, the collar, then the plates on the sleeve, heaviest next to the collar.
    private var barbell: some View {
        let platesWidth = load.perSide.reduce(0) { $0 + plateWidth($1) + Self.plateSpacing }
        return HStack(spacing: 0) {
            Capsule().fill(Self.steel).frame(width: 44, height: 8)
            RoundedRectangle(cornerRadius: 2).fill(Self.steel).frame(width: 9, height: 28)
            ZStack(alignment: .leading) {
                UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3)
                    .fill(Self.steel)
                    .frame(width: max(120, platesWidth + 28), height: 14)
                HStack(spacing: Self.plateSpacing) {
                    ForEach(Array(load.perSide.enumerated()), id: \.offset) { _, plate in plateView(plate) }
                }
                .padding(.leading, Self.plateSpacing)
            }
        }
        .frame(height: 116)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(load.perSide.isEmpty ? "Bar only" : "Each side: " + load.perSide.map {
            "\(WeightFormatter.number($0)) \(inventoryUnit.rawValue)"
        }.joined(separator: ", "))
    }

    private func plateView(_ plate: Double) -> some View {
        let color = PlateColor.of(plate, unit: inventoryUnit)
        return RoundedRectangle(cornerRadius: 3)
            .fill(color.fill)
            .frame(width: plateWidth(plate), height: plateHeight(plate))
            .overlay {
                Text(WeightFormatter.number(plate))
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(color.label)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
            }
    }

    /// Sized by the plate's kilograms, so a pound plate is drawn like its kilogram twin.
    private func plateKg(_ plate: Double) -> CGFloat { CGFloat(UnitConverter.toKg(plate, from: inventoryUnit)) }
    private func plateWidth(_ plate: Double) -> CGFloat { min(26, max(14, plateKg(plate) * 0.5 + 14)) }
    private func plateHeight(_ plate: Double) -> CGFloat { min(112, max(34, plateKg(plate) * 4.2 + 24)) }

    // MARK: List

    private var loadList: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Load each side")
            if load.perSide.isEmpty {
                Text("Bar only, no plates")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("plates.barOnly")
            }
            FlowLayout(spacing: 16, lineSpacing: 6) {
                ForEach(Array(groupedPlates.enumerated()), id: \.offset) { _, group in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(PlateColor.of(group.value, unit: inventoryUnit).fill)
                            .frame(width: 14, height: 14)
                        Text("\(group.count) \u{00D7} \(WeightFormatter.number(group.value)) \(inventoryUnit.rawValue)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("plates.side.\(WeightFormatter.number(group.value))")
                }
            }
            if load.remainder > 0.01 {
                Text("Can't make exactly: \(WeightFormatter.number(load.remainder)) \(inventoryUnit.rawValue) short")
                    .font(.footnote)
                    .foregroundStyle(Theme.record)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct PlateGroup { let value: Double; let count: Int }

    /// `perSide` is heaviest first, so equal plates are neighbours.
    private var groupedPlates: [PlateGroup] {
        load.perSide.reduce(into: []) { groups, plate in
            if let last = groups.last, last.value == plate {
                groups[groups.count - 1] = PlateGroup(value: plate, count: last.count + 1)
            } else {
                groups.append(PlateGroup(value: plate, count: 1))
            }
        }
    }
}
