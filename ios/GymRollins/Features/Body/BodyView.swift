import GymCore
import GymData
import SwiftUI

/// Body tab: the 81 → 85 kg goal card with progress/trend, a range-filtered bodyweight chart,
/// the weigh-in list (swipe to delete), muscle recovery, weekly sets, an "Est. 1RM" card for the most-logged lifts
/// and strength levels (squat/bench/deadlift).
struct BodyView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var entries: [BodyweightEntry] = []
    @State private var topLifts: [LiftTrend] = []
    @State private var range: ChartRange = .month
    @State private var showAddWeighIn = false
    /// Exercise id pushed from the strength-level card.
    @State private var strengthHistory: String?

    private var unit: WeightUnit { env.profile.unit }
    private var trend: BodyTrend {
        BodyTrend(entries: entries, goalKg: env.profile.goalWeightKg, goalDate: env.profile.goalDate, now: env.now())
    }
    private var filteredEntries: [BodyweightEntry] {
        let cutoff = env.now().addingTimeInterval(-Double(range.days) * 86_400)
        return entries.filter { $0.date >= cutoff }
    }
    /// Newest first, for the swipe-to-delete list.
    private var displayEntries: [BodyweightEntry] { entries.reversed() }

    /// `Theme.gutter` on the leading/trailing edges (matching Today/Log's `.padding(.horizontal)`),
    /// since `List` rows default to zero insets rather than the screen's usual horizontal padding.
    private static func rowInsets(top: CGFloat = 0, bottom: CGFloat = 0) -> EdgeInsets {
        EdgeInsets(top: top, leading: Theme.gutter, bottom: bottom, trailing: Theme.gutter)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DisplayTitle(text: "Body", size: 44)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(Self.rowInsets())
                    goalCard
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(Self.rowInsets(top: 4))
                    if !entries.isEmpty {
                        rangePicker
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(Self.rowInsets())
                        BodyweightChart(entries: filteredEntries, goalKg: env.profile.goalWeightKg)
                            .frame(height: 160)
                            .accessibilityIdentifier("body.chart")
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(Self.rowInsets())
                    }
                }
                if !entries.isEmpty {
                    Section {
                        ForEach(Array(displayEntries.enumerated()), id: \.element.id) { index, entry in
                            weighInRow(entry, index: index)
                                .listRowBackground(Color.clear)
                                .listRowInsets(Self.rowInsets(top: 10, bottom: 10))
                        }
                        .onDelete(perform: deleteEntries)
                    }
                }
                Section {
                    RecoveryCard(identifier: "body.recovery")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(Self.rowInsets(top: 6, bottom: 6))
                    WeeklySetsCard()
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(Self.rowInsets(top: 6, bottom: 6))
                }
                if !topLifts.isEmpty {
                    Section {
                        strengthCard
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(Self.rowInsets())
                    }
                }
                Section {
                    StrengthLevelCard { strengthHistory = $0 }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(Self.rowInsets(top: 6, bottom: 6))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationDestination(for: String.self) { ExerciseHistoryView(exerciseId: $0) }
            .navigationDestination(item: $strengthHistory) { ExerciseHistoryView(exerciseId: $0) }
            .sheet(isPresented: $showAddWeighIn) {
                AddWeighInSheet(defaultKg: defaultWeighInKg, now: env.now(), onSaved: reload)
            }
            .task(id: env.dataRevision) { reload() }
        }
    }

    // MARK: Goal card

    private var goalCard: some View {
        SolidCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "Bodyweight goal")
                    Spacer()
                    if let goalDate = env.profile.goalDate {
                        Text("by \(Self.dayMonth(goalDate))")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                }
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(startText).font(Theme.display(44)).foregroundStyle(Theme.textPrimary)
                    Text("\u{2192}").font(.subheadline).foregroundStyle(Theme.textSecondary)
                    Text(goalText).font(Theme.display(44)).foregroundStyle(Theme.accent)
                }
                ProgressView(value: trend.progress)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("body.progress")
                    .accessibilityValue("\(Int((trend.progress * 100).rounded())) percent")
                trendLine
                PrimaryGlassButton(title: "Add weigh-in", identifier: "body.addWeighIn") { showAddWeighIn = true }
            }
        }
    }

    private var startText: String {
        (trend.currentKg ?? trend.startKg).map(WeightFormatter.number) ?? "\u{2014}"
    }

    private var goalText: String {
        guard let goal = env.profile.goalWeightKg else { return "\u{2014}" }
        return "\(WeightFormatter.number(goal)) kg"
    }

    @ViewBuilder
    private var trendLine: some View {
        if let weekly = trend.weeklyChangeKg {
            let projectedText = trend.projectedGoalDate.map { " \u{00B7} on track for \(Self.dayMonth($0))" } ?? ""
            Text("\(signed(weekly)) kg / week\(projectedText)")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("body.trend")
        } else if let required = trend.requiredWeeklyKg, let goalDate = env.profile.goalDate {
            Text("Need \(signed(required)) kg / week to hit \(Self.dayMonth(goalDate))")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("body.trend")
        } else if entries.isEmpty {
            Text("No weigh-ins yet. Weigh in on the same morning each week.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("body.empty")
        } else {
            Text("Add another weigh-in next week to see your trend.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("body.trendPending")
        }
    }

    private func signed(_ kg: Double) -> String {
        let n = WeightFormatter.number(abs(kg))
        return kg < 0 ? "-\(n)" : "+\(n)"
    }

    /// Goal dates (and projected dates) in the device's calendar, the one `SyncDay` stores goal days in.
    private static func dayMonth(_ date: Date) -> String { GoalDate.dayMonth(date) }

    private var defaultWeighInKg: Double { entries.last?.weightKg ?? 81.0 }

    // MARK: Range picker

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(ChartRange.allCases) { r in Text(r.rawValue).tag(r) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("body.range")
    }

    // MARK: Weigh-ins

    private func weighInRow(_ entry: BodyweightEntry, index: Int) -> some View {
        Text(rowText(entry))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .accessibilityIdentifier("body.entry.\(index)")
    }

    private func rowText(_ entry: BodyweightEntry) -> String {
        let date = entry.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let source = entry.source == .appleHealth ? " \u{00B7} Apple Health" : ""
        return "\(date) \u{00B7} \(WeightFormatter.number(entry.weightKg)) kg\(source)"
    }

    private func deleteEntries(_ offsets: IndexSet) {
        for index in offsets {
            try? env.body.delete(displayEntries[index].id)
        }
        env.dataChanged()
        reload()
    }

    // MARK: Strength trends

    private var strengthCard: some View {
        SolidCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Est. 1RM")
                ForEach(topLifts) { lift in
                    NavigationLink(value: lift.exerciseId) {
                        HStack {
                            Text(exerciseName(lift.exerciseId)).font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            HStack(spacing: 4) {
                                Text("e1RM \(WeightFormatter.number(lift.currentKg)) kg")
                                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                                if let arrow = arrow(lift) {
                                    Image(systemName: arrow.icon).font(.caption).foregroundStyle(arrow.color)
                                }
                            }
                        }
                        // The whole row (not just its text line) is the link's hit and accessibility region.
                        .frame(maxWidth: .infinity, minHeight: Theme.minTapSize)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("body.lift.\(lift.exerciseId)")
                }
            }
        }
    }

    private func arrow(_ lift: LiftTrend) -> (icon: String, color: Color)? {
        guard let previous = lift.previousKg else { return nil }
        if lift.currentKg > previous + 0.01 { return ("arrow.up", Theme.success) }
        if lift.currentKg < previous - 0.01 { return ("arrow.down", Theme.destructive) }
        return nil
    }

    private func exerciseName(_ id: String) -> String {
        DisplayName.of(env.library.exercise(id)?.name ?? id)
    }

    // MARK: Data

    private func reload() {
        entries = (try? env.body.entries(since: nil)) ?? []
        topLifts = Self.computeTopLifts(env: env)
    }

    /// The 3 most-logged exercises (by set count across recent workouts) with their latest and
    /// previous estimated 1RM, for the "Est. 1RM" trend card.
    private static func computeTopLifts(env: AppEnvironment) -> [LiftTrend] {
        guard let workouts = try? env.workouts.recent(limit: 200) else { return [] }
        var counts: [String: Int] = [:]
        for w in workouts {
            for e in w.entries { counts[e.exerciseId, default: 0] += 1 }
        }
        let topIds = counts.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        return topIds.compactMap { id in
            guard let sessions = try? env.workouts.sessions(exerciseId: id, limit: 2), let latest = sessions.first,
                  let currentKg = WorkoutMetrics.bestE1RM(latest.entry) else { return nil }
            let previousKg = sessions.count > 1 ? WorkoutMetrics.bestE1RM(sessions[1].entry) : nil
            return LiftTrend(exerciseId: id, currentKg: currentKg, previousKg: previousKg)
        }
    }
}

struct LiftTrend: Identifiable {
    let exerciseId: String
    var id: String { exerciseId }
    let currentKg: Double
    let previousKg: Double?
}
