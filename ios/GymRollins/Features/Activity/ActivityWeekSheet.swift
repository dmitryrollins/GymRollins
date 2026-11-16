import GymCore
import SwiftUI

/// The last 7 days of activity (plan 39), newest first, from Today's Activity row. Days without data aren't listed.
struct ActivityWeekSheet: View {
    /// Oldest first, as `AppEnvironment.recentActivityDays` gives them.
    let days: [ActivityDay]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(days.reversed()) { day in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(day)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    Text(ActivityText.dayLine(day)).font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
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
