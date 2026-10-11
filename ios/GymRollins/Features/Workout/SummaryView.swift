import GymCore
import SwiftUI

/// Post-workout recap: a duration/sets/volume/records stat grid, any new personal records, and a
/// line per exercise. "Done" ends the session and closes the workout cover.
struct SummaryView: View {
    let summary: WorkoutSummary
    let workout: Workout
    let done: () -> Void
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statGrid
                CalorieCard(estimate: env.calories.estimate(workout), healthStatus: env.health.exportStatus(for: workout),
                            prefix: "summary")
                if !summary.records.isEmpty { recordsCard }
                SummaryInsightsSection(workout: workout)
                exerciseList
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 58)
            .padding(.bottom, 110)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) {
            PrimaryGlassButton(title: "Done", identifier: "summary.done", action: done)
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 8)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WORKOUT COMPLETE")
                .font(.footnote.weight(.bold))
                .kerning(0.8)
                .foregroundStyle(Theme.success)
            Text(workout.name)
                .font(Theme.display(44))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityIdentifier("summary.title")
            Text(subtitle).font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
    }

    private var subtitle: String {
        let date = workout.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let count = workout.entries.count
        return "\(date) \u{00B7} \(count) exercise\(count == 1 ? "" : "s")"
    }

    // MARK: Stat grid

    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            stat(label: "Duration", value: DurationFormatter.clock(summary.durationSeconds), identifier: "summary.duration")
            stat(label: "Sets", value: "\(summary.workingSets)", identifier: "summary.sets")
            stat(label: "Volume", value: volumeText, identifier: "summary.volume")
            stat(label: "Records", value: "\(summary.records.count)", identifier: "summary.records", tint: Theme.record)
        }
    }

    private func stat(label: String, value: String, identifier: String, tint: Color = Theme.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(Theme.display(28)).foregroundStyle(tint).accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.card, in: .rect(cornerRadius: 14))
    }

    private var volumeText: String {
        summary.volumeKg >= 1_000
            ? String(format: "%.1f t", summary.volumeKg / 1_000)
            : "\(WeightFormatter.number(summary.volumeKg)) kg"
    }

    // MARK: Records

    private var recordsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NEW RECORDS")
                .font(.footnote.weight(.bold))
                .kerning(0.7)
                .foregroundStyle(Theme.record)
            ForEach(Array(summary.records.enumerated()), id: \.offset) { index, record in
                recordRow(record, index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.record.opacity(0.14), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.record.opacity(0.28), lineWidth: 1)
        }
    }

    private func recordRow(_ record: PersonalRecord, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "trophy.fill").foregroundStyle(Theme.record)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(exerciseName(record.exerciseId)) \u{00B7} \(kindLabel(record.kind))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail(record)).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityIdentifier("summary.record.\(index)")
    }

    private func kindLabel(_ kind: RecordKind) -> String {
        switch kind {
        case .e1RM: "est. 1RM"
        case .repsAtWeight: "rep record"
        case .volume: "volume"
        }
    }

    private func detail(_ record: PersonalRecord) -> String {
        switch record.kind {
        case .e1RM:
            let kg = record.valueKg ?? 0
            let prev = record.previousKg ?? 0
            return "\(WeightFormatter.number(kg)) kg (\(WeightFormatter.number(UnitConverter.fromKg(kg, to: .lb))) lb), " +
                "up from \(WeightFormatter.number(prev))"
        case .repsAtWeight:
            return "\(record.reps ?? 0) reps @ \(WeightFormatter.format(kg: record.weightKg ?? 0, unit: env.profile.unit))"
        case .volume:
            let kg = record.valueKg ?? 0
            let prev = record.previousKg ?? 0
            return "\(WeightFormatter.number(kg)) kg, up from \(WeightFormatter.number(prev)) kg"
        }
    }

    private func exerciseName(_ id: String) -> String {
        DisplayName.of(env.library.exercise(id)?.name ?? id)
    }

    // MARK: Per-exercise lines

    private var exerciseList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(workout.entries) { entry in
                HStack {
                    Text(exerciseName(entry.exerciseId)).font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(entrySummary(entry)).font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) { Divider().background(Theme.divider) }
            }
        }
    }

    private func entrySummary(_ entry: WorkoutEntry) -> String {
        let working = entry.sets.filter { !$0.warmup }
        guard let first = working.first else { return "\(entry.sets.count) sets" }
        return "\(working.count) \u{00D7} \(first.reps) \u{00B7} " +
            WeightFormatter.format(kg: first.weightKg, unit: env.profile.unit, includeSecondary: false)
    }
}
