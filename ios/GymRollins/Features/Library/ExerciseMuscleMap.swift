import GymCore
import SwiftUI

/// How an exercise works one muscle group, which decides its colour on the exercise's body map.
enum MuscleRole: Equatable {
    case target, secondary, none

    /// The role of `group` in an exercise's contributions: primary wins, then secondary, else untouched.
    static func of(_ group: MuscleGroup, in contributions: [MuscleContribution]) -> MuscleRole {
        guard let match = contributions.first(where: { $0.group == group }) else { return .none }
        return match.isPrimary ? .target : .secondary
    }

    var color: Color {
        switch self {
        case .target: Theme.accent
        case .secondary: RecoveryPalette.muscle.mix(with: Theme.record, by: 0.75)
        case .none: RecoveryPalette.muscle
        }
    }
}

/// The exercise's muscles on the front and back body figures: target groups in the accent red, secondary groups
/// in amber, with a key. Draws nothing when the exercise works no group (cardio, an unknown target).
struct ExerciseMuscleMap: View {
    let exercise: Exercise

    var body: some View {
        let contributions = MuscleTaxonomy.contributions(for: exercise)
        if !contributions.isEmpty {
            VStack(spacing: 10) {
                HStack(spacing: 16) {
                    ForEach([BodySide.front, .back], id: \.self) { side in
                        BodyMapView(side: side) { MuscleRole.of($0, in: contributions).color }
                    }
                }
                .frame(height: 220)
                key(Self.keyRoles(contributions))
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.label(contributions))
            .accessibilityIdentifier("detail.muscleMap")
        }
    }

    private func key(_ roles: [MuscleRole]) -> some View {
        HStack(spacing: 12) {
            if roles.contains(.target) { swatch("Target", MuscleRole.target.color) }
            if roles.contains(.secondary) { swatch("Secondary", MuscleRole.secondary.color) }
        }
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
    }

    private func swatch(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }

    /// The colours the key explains: Target when the exercise has a target group, Secondary when it has a secondary
    /// one. An exercise whose target isn't on the map (only its secondary muscles are) shows no Target swatch.
    nonisolated static func keyRoles(_ contributions: [MuscleContribution]) -> [MuscleRole] {
        let hasTarget = contributions.contains(where: \.isPrimary)
        let hasSecondary = contributions.contains { !$0.isPrimary }
        return [MuscleRole.target, .secondary].filter { $0 == .target ? hasTarget : hasSecondary }
    }

    /// "Works chest; also shoulders, triceps".
    nonisolated static func label(_ contributions: [MuscleContribution]) -> String {
        func names(primary: Bool) -> String {
            contributions.filter { $0.isPrimary == primary }.map { $0.group.displayName.lowercased() }
                .joined(separator: ", ")
        }
        let target = names(primary: true), secondary = names(primary: false)
        if target.isEmpty { return "Works \(secondary)" }
        return secondary.isEmpty ? "Works \(target)" : "Works \(target); also \(secondary)"
    }
}
