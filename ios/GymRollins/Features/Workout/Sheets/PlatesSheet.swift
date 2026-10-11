import GymCore
import SwiftUI

/// Plate math for a target weight: big number in the profile unit, a bar+plates stack drawing,
/// and a "load each side" list.
struct PlatesSheet: View {
    let weightKg: Double
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private var unit: WeightUnit { env.profile.unit }
    private var other: WeightUnit { unit == .kg ? .lb : .kg }
    private var load: PlateLoad { PlateCalculator.load(targetKg: weightKg, inventory: env.profile.plateInventory) }
    private var inventoryUnit: WeightUnit { env.profile.plateInventory.unit }

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(Color.white.opacity(0.3)).frame(width: 40, height: 5)
            HStack {
                DisplayTitle(text: "Plate Calculator", size: 28)
                Spacer()
                GlassPillButton(title: "Done", identifier: "plates.done") { dismiss() }
            }
            VStack(spacing: 2) {
                Text("\(WeightFormatter.number(UnitConverter.fromKg(weightKg, to: unit))) \(unit.rawValue)")
                    .font(Theme.display(56))
                Text("\(WeightFormatter.number(UnitConverter.fromKg(weightKg, to: other))) \(other.rawValue) \u{00B7} " +
                     "\(WeightFormatter.number(env.profile.plateInventory.bar)) \(inventoryUnit.rawValue) bar")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            plateStack
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Load each side")
                if load.perSide.isEmpty {
                    Text("Bar only").foregroundStyle(Theme.textSecondary)
                }
                ForEach(Array(groupedPlates.enumerated()), id: \.offset) { _, group in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3).fill(color(for: group.value)).frame(width: 14, height: 14)
                        Text("\(group.count) \u{00D7} \(WeightFormatter.number(group.value)) \(inventoryUnit.rawValue)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .accessibilityIdentifier("plates.side.\(WeightFormatter.number(group.value))")
                }
                if load.remainder > 0.01 {
                    Text("Can't make exactly: \(WeightFormatter.number(load.remainder)) \(inventoryUnit.rawValue) short")
                        .font(.footnote)
                        .foregroundStyle(Theme.record)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.card, in: .rect(cornerRadius: 14))
        }
        .padding(20)
        .presentationDetents([.medium, .large])
    }

    private struct PlateGroup { let value: Double; let count: Int }

    private var groupedPlates: [PlateGroup] {
        var counts: [Double: Int] = [:]
        var order: [Double] = []
        for plate in load.perSide {
            if counts[plate] == nil { order.append(plate) }
            counts[plate, default: 0] += 1
        }
        return order.map { PlateGroup(value: $0, count: counts[$0] ?? 0) }
    }

    private static let palette: [Color] = [
        Color(hex: 0x2F6FE4), Color(hex: 0x3FAE6A), Color(hex: 0xE44F4F), Color(hex: 0xD6A93A), Color(hex: 0x8E8E9A)
    ]

    private func color(for value: Double) -> Color {
        let index = env.profile.plateInventory.plates.sorted(by: >).firstIndex(of: value) ?? 0
        return Self.palette[index % Self.palette.count]
    }

    private var plateStack: some View {
        HStack(alignment: .center, spacing: 4) {
            Rectangle().fill(Theme.textTertiary).frame(width: 70, height: 10).clipShape(.rect(cornerRadius: 2))
            ForEach(Array(load.perSide.enumerated()), id: \.offset) { _, plate in
                RoundedRectangle(cornerRadius: 3)
                    .fill(color(for: plate))
                    .frame(width: barWidth(for: plate), height: barHeight(for: plate))
            }
            Rectangle().fill(Theme.textTertiary).frame(width: 80, height: 10).clipShape(.rect(cornerRadius: 2))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(Theme.card, in: .rect(cornerRadius: 18))
    }

    private func barWidth(for plate: Double) -> CGFloat { max(10, min(24, CGFloat(plate) * 0.35 + 8)) }
    private func barHeight(for plate: Double) -> CGFloat { max(30, min(130, CGFloat(plate) * 2.2 + 20)) }
}
