import GymCore
import SwiftUI

/// Recovery colours: fresh muscles are the figure's plain grey; recovering ones are tinted amber and fatigued ones
/// accent red, more strongly the more fatigued. Limited (injury note) groups are dimmed towards the silhouette.
enum RecoveryPalette {
    /// The silhouette (head, hands, feet and the rim around the muscles).
    static let body = Color(hex: 0x3F4255)
    /// An untouched muscle.
    static let muscle = Color(hex: 0x7F8299)
    /// A muscle held back by the injury note.
    static let limited = body.mix(with: muscle, by: 0.35)

    static func fill(_ recovery: MuscleRecovery, limited: Bool) -> Color {
        if limited { return Self.limited }
        return swatch(recovery.status, fatigue: recovery.fatigue)
    }

    /// The fill for a status at a fatigue level (0…1); the legend uses each status's typical level.
    static func swatch(_ status: RecoveryStatus, fatigue: Double) -> Color {
        switch status {
        case .fresh: muscle
        case .recovering: muscle.mix(with: Theme.record, by: 0.35 + 0.3 * fatigue)
        case .fatigued: muscle.mix(with: Theme.accent, by: 0.5 + 0.4 * fatigue)
        }
    }

    static func tint(_ status: RecoveryStatus) -> Color {
        switch status {
        case .fresh: Theme.success
        case .recovering: Theme.record
        case .fatigued: Theme.accent
        }
    }

    static func label(_ status: RecoveryStatus) -> String {
        switch status {
        case .fresh: "Fresh"
        case .recovering: "Recovering"
        case .fatigued: "Fatigued"
        }
    }
}

/// The front or back figure with each muscle group filled by `fill` (recovery colours by default). Interactive:
/// every group is one button ("Chest, 80% recovered") hit-tested on its own shape. Non-interactive (`onSelect`
/// nil): one hidden image, for a caller that labels the map itself.
struct BodyMapView: View {
    let side: BodySide
    var onSelect: ((MuscleGroup) -> Void)?
    private let fill: (MuscleGroup) -> Color
    private let regionLabel: (MuscleGroup) -> String

    private let data = BodyMapData.shared

    /// The recovery map: each group coloured by its recovery, limited groups dimmed.
    init(side: BodySide, snapshot: InsightsSnapshot, onSelect: ((MuscleGroup) -> Void)? = nil) {
        self.side = side
        self.onSelect = onSelect
        fill = { RecoveryPalette.fill(snapshot.recovery(of: $0), limited: snapshot.limited.contains($0)) }
        regionLabel = snapshot.regionLabel
    }

    /// A map with its own per-group fill. Interactive regions are labelled with the group's name.
    init(side: BodySide, onSelect: ((MuscleGroup) -> Void)? = nil, fill: @escaping (MuscleGroup) -> Color) {
        self.side = side
        self.onSelect = onSelect
        self.fill = fill
        regionLabel = { $0.displayName }
    }

    var body: some View {
        ZStack {
            BodySilhouetteShape(side: side).fill(RecoveryPalette.body)
            ForEach(data.groups(on: side)) { group in
                region(group)
            }
        }
        .aspectRatio(data.aspectRatio(side), contentMode: .fit)
        .accessibilityElement(children: onSelect == nil ? .ignore : .contain)
        .accessibilityHidden(onSelect == nil)
    }

    @ViewBuilder
    private func region(_ group: MuscleGroup) -> some View {
        let shape = MuscleRegionShape(group: group, side: side)
        let filled = shape.fill(fill(group))
        if let onSelect {
            Button { onSelect(group) } label: { filled }
                .buttonStyle(.plain)
                .contentShape(shape)
                .accessibilityLabel(regionLabel(group))
                .accessibilityIdentifier("recovery.region.\(side.rawValue).\(group.rawValue)")
        } else {
            filled
        }
    }
}

/// Fresh / recovering / fatigued / limited key.
struct RecoveryLegend: View {
    var showLimited = false

    var body: some View {
        HStack(spacing: 12) {
            ForEach([RecoveryStatus.fresh, .recovering, .fatigued], id: \.self) { status in
                item(RecoveryPalette.label(status), color: RecoveryPalette.swatch(status, fatigue: 0.5))
            }
            if showLimited { item("Limited", color: RecoveryPalette.limited) }
        }
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
        .accessibilityElement(children: .combine)
    }

    private func item(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}
