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

    /// Recovery, weekly sets and streak as of now. Falls back to an empty snapshot (logged) if the store fails.
    func insights() -> InsightsSnapshot {
        do {
            let since = now().addingTimeInterval(-Double(InsightsSnapshot.windowDays) * 86_400)
            return InsightsSnapshot.make(recent: try workouts.finished(since: since),
                                         startDates: try workouts.finishedStartDates(),
                                         targets: try muscleTargets.all(), profile: profile, library: library,
                                         now: now(), calendar: insightsCalendar)
        } catch {
            Self.log.error("Insights load failed: \(error.localizedDescription, privacy: .public)")
            return .empty
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
