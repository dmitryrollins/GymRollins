import GymCore
import SwiftUI

/// The navigation value of an outside workout's detail (a `UUID` already opens a GymRollins workout's).
struct OutsideWorkoutLink: Hashable {
    let id: UUID
}

/// An outside workout in the Log's history (plan 39), read-only. It shows the kind's icon, the name, the date and
/// duration, and what was measured with where it came from. The outline sets it apart from a GymRollins workout.
struct OutsideWorkoutCard: View {
    let activity: HealthActivity
    let unit: WeightUnit

    var body: some View {
        NavigationLink(value: OutsideWorkoutLink(id: activity.id)) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: ActivityText.symbol(activity))
                    .font(.title3).foregroundStyle(Theme.success)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ActivityText.dateAndDuration(activity)).font(.caption).foregroundStyle(Theme.textSecondary)
                    Text(ActivityText.title(activity)).font(.headline).foregroundStyle(Theme.textPrimary)
                    Text(ActivityText.facts(activity, unit: unit)).font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.divider, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("log.outside.\(activity.id.uuidString)")
    }
}
