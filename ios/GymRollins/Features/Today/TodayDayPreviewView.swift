import GymCore
import SwiftUI

/// A later day on Today, read-only (owner, 2026-11-09): its title, what it trains and the sets suggested as of now, at
/// the current gym. Rows open the exercise; nothing here edits a plan or starts a workout.
struct TodayDayPreviewView: View {
    @Environment(AppEnvironment.self) private var env
    let day: TodayDay
    let onDetails: (String) -> Void
    let onHistory: (String) -> Void
    @State private var model: TodayModel?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                DisplayTitle(text: day.title(now: env.now()), size: 48)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .accessibilityIdentifier("today.title")
                if let model {
                    Text("\(model.title) \u{00B7} \(model.summary)")
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("today.summary")
                }
            }
            if let loadError { Text(loadError).foregroundStyle(Theme.destructive) }
            if let note = model?.gymNote { TodayGymNote(text: note) }
            ForEach(model?.rows ?? []) { row in
                TodayExerciseRow(row: row, exercise: env.library.exercise(row.exerciseId),
                                 onOpen: { onDetails(row.exerciseId) }, openHint: "Opens the exercise") {
                    menu(row)
                }
            }
        }
        .task(id: ReloadKey(day: day, plan: env.planRevision, data: env.dataRevision, gym: env.gymRevision,
                            unit: env.profile.unit)) { load() }
    }

    /// The preview reloads when the day moves, the plan changes (a sync, an agent's change), a workout finishes, the
    /// gym or its equipment changes, or the unit is switched in Settings.
    private struct ReloadKey: Equatable {
        let day: TodayDay
        let plan: Int
        let data: Int
        let gym: Int
        let unit: WeightUnit
    }

    private func menu(_ row: TodayModel.Row) -> some View {
        Menu {
            Button("Video & Instructions", systemImage: "play.rectangle") { onDetails(row.exerciseId) }
            Button("Exercise History", systemImage: "calendar") { onHistory(row.exerciseId) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("More for \(row.name)")
        .accessibilityIdentifier("today.row.menu.\(row.exerciseId)")
    }

    private func load() {
        do {
            let plan = try env.previewPlan(on: day.date(now: env.now()))
            let gym = env.todayGymContext()?.preferring(plan?.builtListings ?? [:])
            model = DayPreview.model(plan: plan, profile: env.profile, library: env.library,
                                     history: { (try? env.workouts.history(exerciseId: $0, limit: 5)) ?? [] },
                                     gym: gym)
            loadError = nil
        } catch {
            AppEnvironment.log.error("Day preview failed: \(error.localizedDescription, privacy: .public)")
            loadError = "Couldn't load this day's plan."
        }
    }
}

/// "1 exercise swapped for this gym. Your plan isn't changed.", on Today and on a later day.
struct TodayGymNote: View {
    let text: String

    var body: some View {
        Text(text).font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.record)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassCapsule(tint: Theme.record.opacity(0.25), interactive: false)
            .accessibilityIdentifier("today.gymNote")
    }
}
