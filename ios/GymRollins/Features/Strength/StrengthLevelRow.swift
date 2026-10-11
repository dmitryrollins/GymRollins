import GymCore
import SwiftUI

/// One lift's level: name + level badge, e1RM and percentile, a bar to the next level and "+15 lb to
/// Intermediate" (or the injury-note pause). Used in the Body card and on the lift's history screen.
struct StrengthLevelRow: View {
    let row: StrengthRow
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.lift.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                if let level = row.assessment?.level {
                    Badge(text: level.displayName, kind: Self.badgeKind(level))
                }
            }
            Text(StrengthText.detail(row, unit: unit)).font(.footnote).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let a = row.assessment {
                ProgressView(value: a.progress).tint(row.paused ? Theme.textTertiary : Theme.accent)
            }
            if let next = StrengthText.next(row, unit: unit) {
                Text(next).font(.footnote.weight(.semibold))
                    .foregroundStyle(row.paused ? Theme.record : Theme.textPrimary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StrengthText.accessibility(row, unit: unit))
    }

    static func badgeKind(_ level: StrengthLevel) -> Badge.Kind {
        switch level {
        case .beginner, .novice: .neutral
        case .intermediate, .advanced: .success
        case .elite: .record
        }
    }
}
