import GymCore
import SwiftUI

/// The last 7 days of activity (plan 39), newest first, from Today's Activity row: each day's date over the same row
/// of cells as Today's, smaller (§4.1). Days without data aren't listed.
struct ActivityWeekSheet: View {
    /// Oldest first, as `AppEnvironment.recentActivityDays` gives them.
    let days: [ActivityDay]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(days.reversed()) { day in
                let metrics = ActivityText.dayMetrics(day)
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.title(day)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    MetricRow(readings: metrics, size: .small, prefix: "activity.cell.\(day.day)")
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.title(day))
                .accessibilityValue(ActivityText.spokenSummary(metrics))
                .accessibilityIdentifier("activity.day.\(day.day)")
                .listRowBackground(Theme.card)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Last 7 days")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("activity.week.done")
                }
            }
        }
        .presentationDetents([.large])
    }

    /// "Saturday 26 Sep".
    private static func title(_ day: ActivityDay) -> String {
        day.date(calendar: .current)?.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)) ?? day.day
    }
}
