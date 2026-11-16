import Foundation
import GymCore
import GymData
import GymHealth

/// Apple Health activities in the app (plan 39):
/// - outside workouts after rules 6 and 7;
/// - days of activity;
/// - what counts toward the streak and the weekly goal;
/// - the two reading switches and the one-time ask.
///
/// A switch that's off only hides its data here: what is stored stays, on this iPhone and in the cloud.
extension AppEnvironment {
    /// Outside workouts that started at or after `since` (all when nil), resolved against the GymRollins workouts
    /// around them; none while "Workouts from other apps" is off. All of them are kept until their data may have
    /// changed (`InsightsMemo`). Falls back to none (logged, not kept) if the store fails.
    func resolvedActivities(since: Date? = nil) -> ResolvedActivities {
        guard health.state.readsOutsideWorkouts else { return .none }
        guard since == nil else { return loadResolvedActivities(since: since) ?? .none }
        let key = insightsDataKey()
        if let key, let memo = insightsMemo.resolved, memo.key == key { return memo.value }
        guard let resolved = loadResolvedActivities(since: nil) else { return .none }
        if let key { insightsMemo.resolved = (key, resolved) }
        return resolved
    }

    /// `resolvedActivities(since:)` read from the store; nil (logged) if it fails.
    private func loadResolvedActivities(since: Date?) -> ResolvedActivities? {
        do {
            // A GymRollins workout that started up to a day earlier can still overlap the first outside workout.
            let spans = try workouts.finishedSpans(since: since?.addingTimeInterval(-86_400))
            return ActivityRules.resolve(try activities.activities(since: since), workouts: spans)
        } catch {
            Self.log.error("Load outside workouts failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Start times of the outside workouts that count toward the streak and the weekly goal (decision 5).
    func countedActivityStarts() -> [Date] {
        resolvedActivities().counted.map(\.startedAt)
    }

    /// What Health measured during this GymRollins workout (rule 6): the Apple Watch's recording first.
    func measuredActivity(for workout: Workout) -> HealthActivity? {
        resolvedActivities(since: workout.startedAt.addingTimeInterval(-86_400)).measured(for: workout.id)
    }

    /// The days of activity among the last `count` days ending today, oldest first (a day without data isn't there);
    /// none while "Steps & activity" is off.
    func recentActivityDays(_ count: Int = 7) -> [ActivityDay] {
        guard health.state.readsActivityDays else { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now())
        guard let first = calendar.date(byAdding: .day, value: -(count - 1), to: today) else { return [] }
        do {
            return try activities.days(from: ActivityDay.key(for: first, calendar: calendar),
                                       through: ActivityDay.key(for: today, calendar: calendar))
        } catch {
            Self.log.error("Load days of activity failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Settings › Apple Health › "Workouts from other apps": screens reload at once; turned on, Health is read now.
    func setReadsOutsideWorkouts(_ on: Bool) {
        health.setReadsOutsideWorkouts(on)
        bumpDataRevision()
        if on { Task { await health.importActivity() } }
    }

    /// Settings › Apple Health › "Steps & activity", the same way.
    func setReadsActivityDays(_ on: Bool) {
        health.setReadsActivityDays(on)
        bumpDataRevision()
        if on { Task { await health.importActivity() } }
    }

    /// The one-time ask (Today's card, Settings › Apple Health): asks Health for the activity types, then imports.
    func allowHealthActivity() async {
        await health.allowActivity()
        bumpDataRevision()
    }
}
