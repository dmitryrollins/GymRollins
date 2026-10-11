import GymCore
import GymData
import GymSync
import SwiftUI

/// One side of a workout conflict, as shown in the review.
struct WorkoutConflictSummary: Equatable {
    let name: String
    let date: String
    let sets: String
    let volume: String

    static func make(_ workout: Workout, unit: WeightUnit) -> WorkoutConflictSummary {
        let count = WorkoutMetrics.workingSetCount(workout)
        return WorkoutConflictSummary(
            name: workout.name,
            date: workout.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
            sets: count == 1 ? "1 set" : "\(count) sets",
            volume: WeightFormatter.format(kg: WorkoutMetrics.volumeKg(workout), unit: unit, includeSecondary: false))
    }
}

/// Reviews workouts edited both on this iPhone and on another device: a side-by-side summary per workout with
/// "Keep this iPhone's" and "Keep other". Closes itself once nothing is left to review.
struct ConflictSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var remote: [UUID: WorkoutConflictSummary] = [:]
    @State private var resolving: UUID?

    private var ids: [UUID] {
        if case .conflicts(let ids) = env.sync.status { return ids }
        return []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("These workouts were changed here and on another device. Choose which version to keep.")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    ForEach(ids, id: \.self) { id in conflictCard(id) }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 12)
            }
            .background(Theme.background)
            .navigationTitle("Review changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }.accessibilityIdentifier("conflict.later")
                }
            }
            .task(id: ids) { await loadRemote() }
            .onChange(of: ids) { _, now in if now.isEmpty { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }

    private func conflictCard(_ id: UUID) -> some View {
        let local = (try? env.workouts.workout(id)).map { WorkoutConflictSummary.make($0, unit: env.profile.unit) }
        return SolidCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    column(title: "This iPhone", summary: local, identifier: "conflict.local")
                    column(title: "Other device", summary: remote[id], identifier: "conflict.remote")
                }
                HStack(spacing: 10) {
                    Button("Keep this iPhone's") { resolve(id, keepLocal: true) }
                        .buttonStyle(.glassProminent).tint(Theme.primaryFill)
                        .accessibilityIdentifier("conflict.keepLocal")
                    Button("Keep other") { resolve(id, keepLocal: false) }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("conflict.keepRemote")
                }
                .disabled(resolving != nil)
            }
        }
    }

    private func column(title: String, summary: WorkoutConflictSummary?, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: title)
            if let summary {
                Text(summary.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Text(summary.date).font(.footnote).foregroundStyle(Theme.textSecondary)
                Text(summary.sets).font(.footnote).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("\(identifier).sets")
                Text(summary.volume).font(.footnote).foregroundStyle(Theme.textSecondary)
            } else {
                Text("Loading\u{2026}").font(.footnote).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadRemote() async {
        for id in ids where remote[id] == nil {
            if let snapshot = await env.sync.remoteWorkout(id: id) {
                remote[id] = WorkoutConflictSummary.make(snapshot.workout, unit: env.profile.unit)
            }
        }
    }

    private func resolve(_ id: UUID, keepLocal: Bool) {
        resolving = id
        Task {
            await env.sync.resolve(conflict: id, keepLocal: keepLocal)
            resolving = nil
        }
    }
}
