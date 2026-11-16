import GymCore
import SwiftUI

/// Today's activity (plan 39):
/// - the one-time "Bring in your Apple Watch activity" card, while Health is on and the activity types were never
///   asked for;
/// - the Activity row with today's steps, move and exercise. A tap shows the last 7 days.
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

    private var row: some View {
        Button { showWeek = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "figure.walk.motion").font(.title3).foregroundStyle(Theme.success)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity").font(.caption).foregroundStyle(Theme.textSecondary)
                    Text(ActivityText.todayLine(today)).font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.plain)
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
