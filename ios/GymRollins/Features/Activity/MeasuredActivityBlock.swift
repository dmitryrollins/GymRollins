import GymCore
import SwiftUI

/// What Health measured during a GymRollins workout (plan 39 rule 6), under its calorie card: "Apple Watch measured"
/// over a compact grid of Fitness-coloured cells (§4.1). Active Calories, Avg. and Max Heart Rate, and Avg. Power when
/// there is one. Hidden when nothing was measured.
struct MeasuredActivityBlock: View {
    let activity: HealthActivity

    var body: some View {
        let readings = ActivityText.measured(activity)
        if !readings.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    if activity.fromWatch { Image(systemName: "applewatch").accessibilityHidden(true) }
                    Text(ActivityText.measuredTitle(activity)).accessibilityIdentifier("detail.measured.title")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
                MetricGrid(readings: readings, size: .compact, prefix: "detail.measured")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("detail.measured")
        }
    }
}
