import GymCore
import SwiftUI

/// The navigation value of an outside workout's detail (a `UUID` already opens a GymRollins workout's).
struct OutsideWorkoutLink: Hashable {
    let id: UUID
}

/// An outside workout in the Log's history (plan 39), read-only, like a row of Fitness' workout list (§4.1): the kind's
/// round icon, its name over the headline metric, and the date over the duration and source. The round icon sets it
/// apart from a GymRollins workout. At accessibility text sizes the date and source go under the metric.
struct OutsideWorkoutCard: View {
    let activity: HealthActivity
    let unit: WeightUnit
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationLink(value: OutsideWorkoutLink(id: activity.id)) {
            HStack(alignment: .center, spacing: 12) {
                MetricIcon(symbol: ActivityText.symbol(activity))
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
                layout {
                    // Both sides wrap rather than truncate: "Traditional Strength Training" needs 2–3 lines here.
                    VStack(alignment: .leading, spacing: 0) {
                        Text(ActivityText.title(activity)).font(.subheadline).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        MetricValueText(reading: ActivityText.headline(activity, unit: unit), size: .medium)
                    }
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                        Text(ActivityText.shortDate(activity))
                        Text(ActivityText.durationAndSource(activity))
                    }
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ActivityText.cardLabel(activity, unit: unit))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("log.outside.\(activity.id.uuidString)")
    }
}
