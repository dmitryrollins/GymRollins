import GymCore
import SwiftUI

/// Solid content row: thumbnail (photo or body-part icon), name, subtitle, optional trailing badge.
struct ExerciseRow: View {
    let exercise: Exercise?
    let fallbackName: String
    let subtitle: String
    var badge: Badge? = nil
    /// Room kept free on the right for a control the caller overlays (e.g. Today's ··· menu), which stays its own
    /// accessibility element instead of being merged into the row.
    var trailingInset: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            ExerciseThumbnail(exercise: exercise)
            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayName.of(exercise?.name ?? fallbackName))
                    .font(.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            if let badge { badge }
        }
        .padding(10)
        .padding(.trailing, trailingInset)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .combine)
    }
}
