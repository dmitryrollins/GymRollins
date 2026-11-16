import GymCore
import SwiftUI

/// An outside workout (plan 39), pushed from its Log card, in the look of Apple Fitness' workout summary (§4.1): the
/// kind's symbol large and faint behind the header, the kind as the title, the headline metric, the date and source,
/// then "Workout Details" with every value Health measured. Nothing can be edited here: Health is the source of truth,
/// so it says where to change it. It reloads whenever the app's data changes, and says so once Health deleted it.
struct OutsideWorkoutDetailView: View {
    let activityId: UUID
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var lookup: OutsideWorkoutLookup?

    /// The band the faint symbol fills above the title. Decorative, so it stays fixed whatever the text size.
    private static let backdropHeight: CGFloat = 190

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                switch lookup {
                case .shown(let activity): content(activity)
                case .removed: removed
                case nil: EmptyView()
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .background(alignment: .top) {
                if case .shown(let activity) = lookup { backdrop(activity) }
            }
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: env.dataRevision) { load() }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.left") }
                .glassCircle()
                .accessibilityLabel("Back")
                .accessibilityIdentifier("outside.back")
            Spacer()
        }
    }

    @ViewBuilder
    private func content(_ activity: HealthActivity) -> some View {
        header(activity)
            .padding(.top, Self.backdropHeight - 64)
        Text("Workout Details")
            .font(.title3.bold()).foregroundStyle(Theme.textPrimary)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 24)
        MetricGrid(readings: ActivityText.details(activity, unit: env.profile.unit), prefix: "outside")
            .padding(16)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
            .padding(.top, 10)
        Text("Change or delete it in the Health app.")
            .font(.footnote).foregroundStyle(Theme.textSecondary)
            .accessibilityIdentifier("outside.healthNote")
            .padding(.top, 14)
    }

    private func header(_ activity: HealthActivity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ActivityText.title(activity))
                .font(.largeTitle.bold()).foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("outside.title")
            let headline = ActivityText.headline(activity, unit: env.profile.unit)
            MetricValueText(reading: headline)
                .accessibilityLabel(headline.spoken)
                .accessibilityIdentifier("outside.headline")
            Group {
                Text(ActivityText.dateAndTimes(activity)).accessibilityIdentifier("outside.date")
                source(activity)
            }
            .font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "⌚ LifeFitness", on its own line under the date (Fitness has one line): the watch only when an Apple Watch
    /// recorded it, as its own "Apple Watch" element. Inside the text, the symbol's spoken name made the line's label
    /// longer than the line, which the accessibility audit flags as clipped.
    private func source(_ activity: HealthActivity) -> some View {
        HStack(spacing: 5) {
            if activity.fromWatch { Image(systemName: "applewatch").accessibilityLabel("Apple Watch") }
            Text(activity.sourceName).accessibilityIdentifier("outside.source")
        }
    }

    /// The kind's symbol, very large and faint behind the top bar and above the title, like the big bike in Fitness.
    private func backdrop(_ activity: HealthActivity) -> some View {
        Image(systemName: ActivityText.symbol(activity))
            .font(.system(size: Self.backdropHeight * 0.8))
            .foregroundStyle(Color.white.opacity(0.08))
            .frame(maxWidth: .infinity)
            .frame(height: Self.backdropHeight)
            .accessibilityHidden(true)
    }

    private var removed: some View {
        Text("This workout was removed from Health.")
            .font(.body).foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 24)
            .accessibilityIdentifier("outside.removed")
    }

    private func load() {
        if let found = env.outsideWorkout(activityId) { lookup = found }
    }
}
