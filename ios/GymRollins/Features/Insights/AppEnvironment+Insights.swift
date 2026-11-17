import Foundation
import GymCore
import GymData

extension AppEnvironment {
    var muscleTargets: MuscleTargetRepository { MuscleTargetRepository(context: container.mainContext, now: now) }

    /// Weeks run Monday–Sunday in the device's time zone (like the Log tab's week strip).
    var insightsCalendar: Calendar { TrainingWeek.calendar(timeZone: .current) }

    /// Changes whenever something the insights depend on changes (workouts, targets, the goal, the limits note).
    var insightsRevision: String {
        "\(dataRevision)-\(planRevision)-\(profile.trainingDays)-\(profile.limits)"
    }

    /// Recovery, weekly sets and streak as of now; the streak counts the outside workouts that count (plan 39). Reused
    /// within the minute until its data, plan, goal or limits note change (`InsightsMemo`). Falls back to an empty
    /// snapshot (logged, not kept) if the store fails.
    func insights() -> InsightsSnapshot {
        let time = now()
        let calendar = insightsCalendar
        let key = insightsDataKey().map {
            InsightsMemo.SnapshotKey(data: $0, revision: insightsRevision, timeZone: calendar.timeZone.identifier,
                                     minute: Int((time.timeIntervalSinceReferenceDate / 60).rounded(.down)))
        }
        if let key, let memo = insightsMemo.snapshot, memo.key == key { return memo.value }
        do {
            let since = time.addingTimeInterval(-Double(InsightsSnapshot.windowDays) * 86_400)
            let snapshot = InsightsSnapshot.make(recent: try workouts.finished(since: since),
                                                 startDates: try workouts.finishedStartDates() + countedActivityStarts(),
                                                 targets: try muscleTargets.all(), profile: profile, library: library,
                                                 now: time, calendar: calendar)
            if let key { insightsMemo.snapshot = (key, snapshot) }
            return snapshot
        } catch {
            Self.log.error("Insights load failed: \(error.localizedDescription, privacy: .public)")
            return .empty
        }
    }

    /// What the insights and the resolved outside workouts were made from (`InsightsMemo.DataKey`); nil (logged) when
    /// the store can't be counted, and then nothing is reused.
    func insightsDataKey() -> InsightsMemo.DataKey? {
        do {
            return InsightsMemo.DataKey(revision: dataRevision, readsOutsideWorkouts: health.state.readsOutsideWorkouts,
                                        workouts: try workouts.finishedCount(),
                                        outsideWorkouts: try activities.liveCount())
        } catch {
            Self.log.error("Insights data check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The window's workouts (for a muscle's recent sets).
    func recentWorkouts() -> [Workout] {
        let since = now().addingTimeInterval(-Double(InsightsSnapshot.windowDays) * 86_400)
        do { return try workouts.finished(since: since) } catch {
            Self.log.error("Recent workouts load failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// True when finishing `workout` brought its week to the weekly goal. The outside workouts that count are workout
    /// days of that week too (plan 39, decision 5).
    func completesWeeklyGoal(_ workout: Workout) throws -> Bool {
        let week = TrainingWeek.interval(containing: workout.startedAt, calendar: insightsCalendar)
        let others = try workouts.finished(since: week.start).filter { $0.id != workout.id }.map(\.startedAt)
        return StreakCalculator.completesWeeklyGoal(otherDates: others + countedActivityStarts(),
                                                    finished: workout.startedAt, goal: profile.trainingDays,
                                                    calendar: insightsCalendar)
    }

    /// Saves a weekly target and schedules a sync.
    func setMuscleTarget(_ group: MuscleGroup, _ range: SetTargetRange) throws {
        try muscleTargets.set(group, range)
        dataChanged()
    }

    func resetMuscleTargets() throws {
        try muscleTargets.resetAll()
        dataChanged()
    }
}
