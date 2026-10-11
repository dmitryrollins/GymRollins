import GymCore
import SwiftUI

/// Today header chip: "🔥 3 wk" style streak (SF Symbol, no emoji).
struct StreakChip: View {
    @Environment(AppEnvironment.self) private var env
    @State private var snapshot = InsightsSnapshot.empty

    var body: some View {
        Label(snapshot.streakChipText, systemImage: "flame.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(snapshot.streak.current > 0 ? Theme.record : Theme.textSecondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassCapsule(interactive: false)
            .frame(minHeight: Theme.minTapSize) // audit: the element's frame is its hit region
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(snapshot.streakAccessibility)
            .accessibilityIdentifier("today.streak")
            .insightsRefresh { snapshot = env.insights() }
    }
}

/// Log tab: current and longest streak, and this week's progress toward the goal.
struct StreakCard: View {
    @Environment(AppEnvironment.self) private var env
    @State private var snapshot = InsightsSnapshot.empty

    var body: some View {
        SolidCard {
            HStack(spacing: 0) {
                stat("Current", value: weeks(snapshot.streak.current), tint: Theme.record)
                stat("Longest", value: weeks(snapshot.streak.longest), tint: Theme.textPrimary)
                stat("This week", value: "\(snapshot.streak.thisWeekDays)/\(snapshot.streak.goal)",
                     tint: snapshot.streak.thisWeekMet ? Theme.success : Theme.textPrimary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.streakAccessibility
                            + " Longest: \(weeks(snapshot.streak.longest, spoken: true)).")
        .accessibilityIdentifier("log.streak")
        .insightsRefresh { snapshot = env.insights() }
    }

    private func weeks(_ n: Int, spoken: Bool = false) -> String {
        spoken ? (n == 1 ? "1 week" : "\(n) weeks") : "\(n) wk"
    }

    private func stat(_ label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.caption2.weight(.bold)).kerning(0.8).foregroundStyle(Theme.textTertiary)
            HStack(spacing: 4) {
                if label == "Current" { Image(systemName: "flame.fill").font(.subheadline).foregroundStyle(tint) }
                Text(value).font(Theme.display(26)).foregroundStyle(tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Summary: this workout's muscles against their weekly targets, and a celebration when it completed the week's
/// workout goal (the flame bounces once unless Reduce Motion is on).
struct SummaryInsightsSection: View {
    let workout: Workout
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var snapshot: InsightsSnapshot?
    @State private var completedWeek = false
    @State private var bounce = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if completedWeek, let snapshot { celebration(snapshot) }
            if let snapshot, !trainedGroups.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Weekly sets")
                    ForEach(trainedGroups) { group in
                        Text(snapshot.weeklyLine(group)).font(.footnote).foregroundStyle(Theme.textSecondary)
                            .accessibilityIdentifier("summary.weekly.\(group.rawValue)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.card, in: .rect(cornerRadius: 14))
            }
        }
        .task { load() }
    }

    /// Primary groups this workout trained, in body order (at most 4, to keep the summary short).
    private var trainedGroups: [MuscleGroup] {
        let primaries = Set(workout.entries.flatMap { entry -> [MuscleGroup] in
            guard entry.sets.contains(where: HardSets.isHard), let ex = env.library.exercise(entry.exerciseId)
            else { return [] }
            return MuscleTaxonomy.contributions(for: ex).filter(\.isPrimary).map(\.group)
        })
        return Array(MuscleGroup.allCases.filter(primaries.contains).prefix(4))
    }

    private func celebration(_ snapshot: InsightsSnapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "flame.fill").font(.title2).foregroundStyle(Theme.record)
                .symbolEffect(.bounce, value: bounce)
            VStack(alignment: .leading, spacing: 2) {
                Text("Week complete").font(.headline).foregroundStyle(Theme.textPrimary)
                Text("\(snapshot.streak.goal) of \(snapshot.streak.goal) workouts \u{00B7} "
                     + (snapshot.streak.current == 1 ? "1-week streak" : "\(snapshot.streak.current)-week streak"))
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.record.opacity(0.14), in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.record.opacity(0.28), lineWidth: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("summary.weekComplete")
    }

    private func load() {
        let current = env.insights()
        snapshot = current
        let week = TrainingWeek.interval(containing: workout.startedAt, calendar: env.insightsCalendar)
        do {
            let others = try env.workouts.finished(since: week.start).filter { $0.id != workout.id }
            completedWeek = StreakCalculator.completesWeeklyGoal(otherDates: others.map(\.startedAt),
                                                                 finished: workout.startedAt,
                                                                 goal: env.profile.trainingDays,
                                                                 calendar: env.insightsCalendar)
        } catch {
            AppEnvironment.log.error("Weekly goal check failed: \(error.localizedDescription, privacy: .public)")
            completedWeek = false
        }
        guard completedWeek, !reduceMotion else { return }
        Task { // after the card is on screen, so the bounce is visible
            try? await Task.sleep(for: .milliseconds(350))
            bounce += 1
        }
    }
}
