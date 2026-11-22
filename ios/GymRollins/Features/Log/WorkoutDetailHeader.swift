import GymCore
import SwiftUI

/// The workout detail's header (spec §4): the strength symbol in a round green-yellow tint (`MetricIcon`), the name in
/// SF Pro bold, the workout time in green-yellow, the date and times, what recorded it, and who added it when an agent
/// did.
struct WorkoutDetailHeader: View {
    let workout: Workout
    /// Nil until the workout is read.
    let summary: MeasuredSummary?
    let addedBy: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                MetricIcon(symbol: OutsideWorkoutKind.traditionalStrength.symbol)
                Text(workout.name)
                    .font(Theme.display(34)).foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            if let summary {
                let headline = MeasuredText.headline(summary)
                MetricValueText(reading: headline)
                    .accessibilityLabel("\(headline.label), \(headline.spoken)")
                    .accessibilityIdentifier("detail.headline")
            }
            Group {
                Text(MeasuredText.dateAndTimes(start: workout.startedAt, end: workout.endedAt ?? workout.startedAt))
                    .accessibilityIdentifier("detail.date")
                if let recorded = MeasuredText.recordedBy(summary?.source ?? .estimate,
                                                          loggedHere: workout.source == .app && addedBy == nil) {
                    // The symbol is its own decorative image: inside the text, its spoken name made the label longer
                    // than the line (plan 39 §4.1's audit finding).
                    HStack(spacing: 5) {
                        Image(systemName: recorded.symbol).accessibilityHidden(true)
                        Text(recorded.text).accessibilityIdentifier("detail.recordedBy")
                    }
                }
                if let addedBy {
                    Text(AgentText.addedBy(addedBy)).accessibilityIdentifier("detail.addedBy")
                }
            }
            .font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
