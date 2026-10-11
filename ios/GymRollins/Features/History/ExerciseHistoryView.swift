import Charts
import GymCore
import SwiftUI

/// History (list) / Trends (Swift Charts e1RM line) for one exercise, opened from Logging's
/// History chip (as a sheet, wrapped in its own `NavigationStack` at the presentation site) or
/// pushed from Body's strength row (inside Body's existing `NavigationStack`). Never wraps its
/// own `NavigationStack`: nesting one inside the caller's stack breaks the push from Body.
struct ExerciseHistoryView: View {
    let exerciseId: String
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var section = 0
    @State private var history: [SessionResult] = []
    @State private var sessions: [(date: Date, entry: WorkoutEntry)] = []
    @State private var strength: StrengthReport?

    private var unit: WeightUnit { env.profile.unit }
    private var exerciseName: String { DisplayName.of(env.library.exercise(exerciseId)?.name ?? exerciseId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DisplayTitle(text: exerciseName, size: 30)
                if let lift = StrengthLift.lift(forExercise: exerciseId) { strengthCard(lift) }
                Picker("Section", selection: $section) {
                    Text("History").tag(0)
                    Text("Trends").tag(1)
                }
                .pickerStyle(.segmented)
                if section == 0 { historyList } else { trends }
            }
            .padding(20)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: exerciseId) {
            history = (try? env.workouts.history(exerciseId: exerciseId, limit: 20)) ?? []
            sessions = (try? env.workouts.sessions(exerciseId: exerciseId, limit: 20)) ?? []
        }
        .insightsRefresh {
            strength = StrengthLift.lift(forExercise: exerciseId) == nil ? nil : env.strengthReport()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }.accessibilityIdentifier("history.close")
            }
        }
    }

    // MARK: Strength level

    @ViewBuilder
    private func strengthCard(_ lift: StrengthLift) -> some View {
        if let report = strength, let row = report.row(lift) {
            SolidCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Strength level")
                    StrengthLevelRow(row: row, unit: unit)
                    if let missing = StrengthText.missing(report.missing) {
                        Text(missing + " (Body tab \u{203A} Strength level)")
                            .font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("history.strength")
        }
    }

    // MARK: History

    @ViewBuilder
    private var historyList: some View {
        if history.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                ForEach(Array(history.enumerated()), id: \.offset) { _, session in
                    HStack {
                        Text(session.date.formatted(.dateTime.day().month(.abbreviated)))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(sessionSummary(session)).font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Divider().background(Theme.divider) }
                }
            }
        }
    }

    private func sessionSummary(_ session: SessionResult) -> String {
        "\(session.reps.count) \u{00D7} \(session.reps.first ?? 0) @ " + WeightFormatter.format(kg: session.weightKg, unit: unit)
    }

    // MARK: Trends

    @ViewBuilder
    private var trends: some View {
        if history.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 10) {
                SolidCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Est. 1RM")
                        Chart(ExerciseTrends.points(sessions)) { point in
                            LineMark(x: .value("Date", point.date), y: .value("e1RM", point.e1RMKg))
                            PointMark(x: .value("Date", point.date), y: .value("e1RM", point.e1RMKg))
                        }
                        .foregroundStyle(Theme.accent)
                        .frame(height: 140)
                        .accessibilityIdentifier("history.chart")
                    }
                }
                if let best = ExerciseTrends.bestSet(sessions) {
                    SolidCard {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(text: "Best set")
                            Text("\(WeightFormatter.format(kg: best.weightKg, unit: unit, includeSecondary: false)) " +
                                 "\u{00D7} \(best.reps)")
                                .font(Theme.display(26))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        Text("No history yet.").foregroundStyle(Theme.textSecondary)
    }
}

/// e1RM trend and best set from every working set of each session (not just the top-weight sets
/// a progression `SessionResult` keeps), matching WorkoutMetrics and record detection.
enum ExerciseTrends {
    struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let e1RMKg: Double
    }

    /// One point per session (oldest first) at that session's best estimated 1RM.
    static func points(_ sessions: [(date: Date, entry: WorkoutEntry)]) -> [Point] {
        sessions.reversed().compactMap { session in
            WorkoutMetrics.bestE1RM(session.entry).map { Point(date: session.date, e1RMKg: $0) }
        }
    }

    static func bestSet(_ sessions: [(date: Date, entry: WorkoutEntry)]) -> WorkoutSet? {
        sessions.compactMap { WorkoutMetrics.bestE1RMSet($0.entry) }.max { lhs, rhs in
            (OneRepMax.estimate(weightKg: lhs.weightKg, reps: lhs.reps) ?? 0) <
                (OneRepMax.estimate(weightKg: rhs.weightKg, reps: rhs.reps) ?? 0)
        }
    }
}
