import GymCore
import SwiftUI

/// Today's activity (plan 39):
/// - the one-time "Bring in your Apple Watch activity" card, while Health is on and the activity types were never
///   asked for;
/// - the Activity row with today's steps, move, exercise and stand, in Apple Fitness' colours (§4.1). A tap shows the
///   last 7 days.
///
/// The row hides while "Steps & activity" is off or the last 7 days have no data.
struct TodayActivitySection: View {
    /// The last 7 days, oldest first (`AppEnvironment.recentActivityDays`).
    let days: [ActivityDay]
    @Environment(AppEnvironment.self) private var env
    @State private var showWeek = false
    @State private var asking = false

    var body: some View {
        Group {
            if env.health.showsActivityCard {
                ActivityPermissionCard(asking: asking, allow: allow, notNow: { env.health.dismissActivityCard() })
            }
            if !days.isEmpty { row }
        }
    }

    private var today: ActivityDay? {
        days.first { $0.day == ActivityDay.key(for: env.now(), calendar: .current) }
    }

    /// A card titled "Activity" with a chevron, over one row of Fitness-coloured cells (§4.1).
    private var row: some View {
        let metrics = ActivityText.dayMetrics(today)
        return Button { showWeek = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Activity").font(.headline).foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                MetricRow(readings: metrics, prefix: "today.activity")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Activity")
        .accessibilityValue(ActivityText.spokenSummary(metrics))
        .accessibilityHint("Shows the last 7 days")
        .accessibilityIdentifier("today.activity")
        .sheet(isPresented: $showWeek) { ActivityWeekSheet(days: days) }
    }

    private func allow() {
        guard !asking else { return }
        asking = true
        Task {
            await env.allowHealthActivity()
            asking = false
        }
    }
}
