import GymCore
import SwiftUI

/// What an exercise's muscle badge shows: the side that shows its primary muscles best, zoomed to the upper or
/// lower body when they all sit there, with primary groups bright and secondary ones dimmer.
struct MuscleBadgeLayout: Equatable {
    enum Zoom: Equatable { case upper, lower, whole }

    let side: BodySide
    let zoom: Zoom
    let primary: Set<MuscleGroup>
    let secondary: Set<MuscleGroup>

    /// nil when the exercise has no known muscles (the badge is then hidden).
    init?(contributions: [MuscleContribution]) {
        let primary = Set(contributions.filter(\.isPrimary).map(\.group))
        guard !primary.isEmpty else { return nil }
        self.primary = primary
        secondary = Set(contributions.filter { !$0.isPrimary }.map(\.group)).subtracting(primary)
        let backVotes = primary.filter { Self.backGroups.contains($0) }.count
        side = backVotes * 2 > primary.count ? .back : .front
        if primary.isSubset(of: Self.upperGroups) {
            zoom = .upper
        } else if primary.isSubset(of: Self.lowerGroups) {
            zoom = .lower
        } else {
            zoom = .whole
        }
    }

    /// Groups seen best from behind.
    static let backGroups: Set<MuscleGroup> = [
        .traps, .upperBack, .lats, .lowerBack, .triceps, .glutes, .abductors, .hamstrings, .calves,
    ]
    /// Shoulders to waist (forearms reach past the upper crop, so they show the whole figure).
    static let upperGroups: Set<MuscleGroup> = [
        .chest, .shoulders, .traps, .upperBack, .lats, .lowerBack, .biceps, .triceps, .abs,
    ]
    static let lowerGroups: Set<MuscleGroup> = [.glutes, .abductors, .adductors, .quads, .hamstrings, .calves]

    /// The square of the figure to show, in source units; nil = the whole view box.
    func box(in data: BodyMapData) -> CGRect? {
        let midX = data.viewBox(side).midX
        switch zoom {
        case .upper: return CGRect(x: midX - 240, y: 215, width: 480, height: 480) // neck to hips
        case .lower: return CGRect(x: midX - 330, y: 690, width: 660, height: 660) // hips to feet
        case .whole: return nil
        }
    }
}

/// Small figure with an exercise's target muscles lit, shown on the corner of its thumbnail.
struct MuscleBadge: View {
    let layout: MuscleBadgeLayout
    var size: CGFloat = 30

    private let data = BodyMapData.shared

    var body: some View {
        let box = layout.box(in: data)
        ZStack {
            BodySilhouetteShape(side: layout.side, box: box).fill(RecoveryPalette.body)
            ForEach(data.groups(on: layout.side)) { group in
                MuscleRegionShape(group: group, side: layout.side, box: box).fill(color(group))
            }
        }
        .padding(layout.zoom == .whole ? size * 0.06 : 0)
        .frame(width: size, height: size)
        .background(Theme.cardInner)
        .clipShape(.rect(cornerRadius: size * 0.22))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.22).stroke(Theme.background, lineWidth: 1.5)
        }
        .accessibilityHidden(true)
    }

    private func color(_ group: MuscleGroup) -> Color {
        if layout.primary.contains(group) { return .white }
        if layout.secondary.contains(group) { return RecoveryPalette.muscle.mix(with: .white, by: 0.45) }
        return RecoveryPalette.muscle
    }
}
