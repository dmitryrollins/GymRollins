import GymCore
import SwiftUI

/// An outside workout (plan 39), pushed from its Log card. It shows what Health measured, with average and maximum
/// heart rate. Nothing can be edited here: Health is the source of truth, so it says where to change it.
struct OutsideWorkoutDetailView: View {
    let activityId: UUID
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var activity: HealthActivity?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }
                        .glassCircle()
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("outside.back")
                    Spacer()
                }
                if let activity { content(activity) }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: activityId) { load() }
    }

    @ViewBuilder
    private func content(_ activity: HealthActivity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(activity.startedAt.formatted(
                .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                Image(systemName: ActivityText.symbol(activity)).font(.title2).foregroundStyle(Theme.success)
                    .accessibilityHidden(true)
                Text(ActivityText.title(activity)).font(Theme.display(34)).foregroundStyle(Theme.textPrimary)
                    .accessibilityIdentifier("outside.title")
            }
            Text("From \(activity.sourceName)").font(.footnote).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("outside.source")
        }
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            stat("Duration", DurationFormatter.hoursMinutes(activity.durationS), identifier: "outside.duration")
            if let distance = ActivityText.distance(activity, unit: env.profile.unit) {
                stat("Distance", distance, identifier: "outside.distance")
            }
            if let kcal = activity.kcal {
                stat("Active calories", "\(Int(kcal.rounded()).formatted()) kcal", identifier: "outside.kcal")
            }
            if let avg = activity.avgHr { stat("Avg heart rate", "\(avg) bpm", identifier: "outside.avgHr") }
            if let max = activity.maxHr { stat("Max heart rate", "\(max) bpm", identifier: "outside.maxHr") }
        }
        Text("Change or delete it in the Health app.")
            .font(.footnote).foregroundStyle(Theme.textSecondary)
            .accessibilityIdentifier("outside.healthNote")
    }

    private func stat(_ label: String, _ value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(Theme.display(22)).foregroundStyle(Theme.textPrimary).accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.card, in: .rect(cornerRadius: 14))
    }

    private func load() {
        do { activity = try env.activities.activity(activityId) } catch {
            AppEnvironment.log.error("Load outside workout failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
