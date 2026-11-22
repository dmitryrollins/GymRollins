import GymCore
import GymData
import SwiftUI

/// Log tab: a solid week-activity strip (minutes per day, outside workouts' in a lighter shade), the week's calories,
/// and the history: GymRollins workouts lazily paged 50 at a time, with the outside workouts from Apple Health between
/// them (plan 39). Tapping a card pushes `WorkoutDetailView` or `OutsideWorkoutDetailView`; the header's "R" pushes
/// Settings. Pull to refresh syncs.
struct LogView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var workouts: [Workout] = []
    /// Outside workouts shown on their own (rules 6 and 7), newest first.
    @State private var outside: [HealthActivity] = []
    /// The history: `workouts` with `outside` between them.
    @State private var items: [LogItem] = []
    @State private var recordCounts: [UUID: Int] = [:]
    @State private var limit = 50
    @State private var showSettings = false
    @State private var isLoadingMore = false
    @State private var showWorkout = false
    @State private var showImport = false
    @State private var showCalorieInfo = false

    private static let dayLetters = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
    private static let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    private static func spokenDay(_ day: WeekActivity.Day) -> String {
        let trained = day.minutes > 0 ? "\(day.minutes) minutes trained" : nil
        let other = day.outsideMinutes > 0 ? "\(day.outsideMinutes) minutes of other activity" : nil
        let none = trained == nil && other == nil ? "no workout" : nil
        return [dayNames[day.weekday - 1], day.isToday ? "today" : nil, trained, other, none].compactMap { $0 }
            .joined(separator: ", ")
    }

    /// The week strip's tiles, on its card: a day with a GymRollins workout is the near-solid accent under a dark label
    /// (white on it measured below 4.5:1); a day with only outside workouts a lighter shade, dark enough for white.
    /// `ThemeContrastTests` checks both on the card.
    static let trainedTile = (fill: Theme.accent.opacity(0.85), label: Theme.background)
    static let outsideTile = (fill: Theme.accent.opacity(0.35), label: Theme.textPrimary)

    private static func fill(_ day: WeekActivity.Day) -> Color {
        if day.minutes > 0 { return trainedTile.fill }
        return day.outsideMinutes > 0 ? outsideTile.fill : Theme.cardInner
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SyncStatusBanner()
                    weekStrip
                    weekCalories
                    StreakCard()
                    SectionLabel(text: "Past workouts")
                    pastWorkouts
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 130)
            }
            .fixedHeader { TabHeader(title: "Log", prefix: "log") { showSettings = true } }
            .background(Theme.background)
            .refreshable { await env.sync.syncNow() }
            .navigationDestination(for: UUID.self) { WorkoutDetailView(workoutId: $0) }
            .navigationDestination(for: OutsideWorkoutLink.self) { OutsideWorkoutDetailView(activityId: $0.id) }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .navigationDestination(isPresented: $showImport) {
                ImportCSVView(onBack: { showImport = false }, onDone: { showImport = false })
            }
            .fullScreenCover(isPresented: $showWorkout) {
                if let session = env.session { WorkoutFlowView(session: session) }
            }
            .task(id: env.dataRevision) { reload() }
        }
    }

    private var weekStrip: some View {
        let week = WeekActivity(workouts: workouts, outside: outside, containing: env.now())
        return SolidCard {
            HStack(spacing: 4) {
                ForEach(week.days) { day in
                    VStack(spacing: 4) {
                        Text(Self.dayLetters[day.weekday - 1]).font(.caption2)
                            .foregroundStyle(day.isToday ? Theme.textPrimary : Theme.textSecondary)
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Self.fill(day))
                            if day.isToday {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [3]))
                            }
                            if day.minutes + day.outsideMinutes > 0 {
                                Text(DurationFormatter.minutes(TimeInterval((day.minutes + day.outsideMinutes) * 60)))
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(day.minutes > 0 ? Self.trainedTile.label : Self.outsideTile.label)
                                    .minimumScaleFactor(0.7)
                                    .lineLimit(1)
                            }
                        }
                        .frame(minHeight: 30)
                    }
                    .frame(maxWidth: .infinity)
                    // One spoken element per day ("Monday, 45 minutes trained") laid over the letter + tile, which
                    // are hidden: combined, the audit measured the tile fill as low-contrast text, and a label on the
                    // two-letter text itself reads as clipped.
                    .accessibilityHidden(true)
                    .overlay {
                        Color.clear
                            .accessibilityElement()
                            .accessibilityLabel(Self.spokenDay(day))
                            .accessibilityIdentifier("log.week.\(day.weekday)")
                    }
                }
            }
        }
    }

    /// "≈ 1,240 kcal this week (estimated)" under the strip, with the method sheet, and apart from it what Health
    /// measured for the week's outside workouts (decision 10: never added to the estimate).
    @ViewBuilder
    private var weekCalories: some View {
        let total = env.calories.weekTotal(of: workouts, containing: env.now())
        let other = ActivityText.weekKcal(outside, containing: env.now())
        if total > 0 {
            HStack {
                Text("\(CalorieText.kcal(total)) this week (estimated)")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("log.week.kcal")
                Spacer()
                Button { showCalorieInfo = true } label: { Image(systemName: "info.circle") }
                    .glassCircle()
                    .accessibilityLabel("How calories are estimated")
                    .accessibilityIdentifier("log.week.kcal.info")
            }
            .sheet(isPresented: $showCalorieInfo) { CalorieInfoSheet(estimate: nil) }
        }
        if other > 0 {
            Text(ActivityText.otherKcalLine(other))
                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("log.week.otherKcal")
        }
    }

    @ViewBuilder
    private var pastWorkouts: some View {
        if items.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: 8) {
                ForEach(items) { item in
                    Group {
                        switch item {
                        case .workout(let workout):
                            WorkoutCard(workout: workout, recordCount: recordCounts[workout.id] ?? 0,
                                        unit: env.profile.unit, library: env.library)
                        case .outside(let activity):
                            OutsideWorkoutCard(activity: activity, unit: env.profile.unit)
                        }
                    }
                    .onAppear {
                        if item.id == items.last?.id { loadMore() }
                    }
                }
            }
        }
    }

    /// First-run: no workouts logged or imported yet.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No workouts yet").font(.headline).accessibilityIdentifier("log.empty.title")
            Text("Start your first workout or import a CSV")
                .font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            if env.session != nil {
                SecondaryGlassButton(title: "Resume Workout", identifier: "log.empty.resumeWorkout") {
                    showWorkout = true
                }
            } else {
                SecondaryGlassButton(title: "Start a Workout", identifier: "log.empty.startWorkout") {
                    env.startSession(routine: nil)
                    showWorkout = true
                }
            }
            SecondaryGlassButton(title: "Import a CSV", identifier: "log.empty.importCSV") { showImport = true }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func reload() {
        workouts = (try? env.workouts.recent(limit: limit)) ?? []
        recordCounts = (try? env.workouts.recordCounts(ids: workouts.map(\.id))) ?? [:]
        outside = env.resolvedActivities().shown
        items = LogTimeline.merge(workouts: workouts, outside: outside, complete: workouts.count < limit)
    }

    /// `LazyVStack` still calls `onAppear` for the last row on every reload pass while it's the
    /// bottom row; `isLoadingMore` keeps a re-trigger during that pass from stacking another
    /// `limit` bump before the fetched page has replaced it.
    private func loadMore() {
        guard !isLoadingMore, workouts.count >= limit else { return }
        isLoadingMore = true
        limit += 50
        reload()
        isLoadingMore = false
    }
}
