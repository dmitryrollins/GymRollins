import GymCore
import SwiftUI

/// Solid content row: thumbnail (photo or body-part icon), name, subtitle, an optional note line, optional trailing
/// badge. A gym `photoFile` replaces the exercise thumbnail.
struct ExerciseRow: View {
    let exercise: Exercise?
    let fallbackName: String
    let subtitle: String
    var badge: Badge? = nil
    var note: String? = nil
    var photoFile: String? = nil
    /// Room kept free on the right for a control the caller overlays (e.g. Today's ··· menu), which stays its own
    /// accessibility element instead of being merged into the row.
    var trailingInset: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            if let photoFile { GymPhotoView(fileName: photoFile) } else { ExerciseThumbnail(exercise: exercise) }
            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayName.of(exercise?.name ?? fallbackName))
                    .font(.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                // With a note the row is crowded: the badge sits under the name and the text keeps the full width.
                if note != nil, let badge { badge }
                Text(subtitle).font(.footnote).foregroundStyle(Theme.textSecondary)
                if let note { Text(note).font(.caption).foregroundStyle(Theme.textSecondary) }
            }
            Spacer(minLength: 8)
            if note == nil, let badge { badge }
        }
        .padding(10)
        .padding(.trailing, trailingInset)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .combine)
    }
}
