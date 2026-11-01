import Foundation
import GymCore

extension Notification.Name {
    /// Today's plan was replaced from outside Today: Today reloads.
    static let todayPlanReplaced = Notification.Name("gymrollins.todayPlanReplaced")
    /// The incoming sheet's Resume: Today opens the running workout.
    static let resumeWorkoutRequested = Notification.Name("gymrollins.resumeWorkoutRequested")
}

/// Workout links (docs/specs/2026-11-01-shared-workout-design.md).
extension AppEnvironment {
    func incomingWorkoutScreen(url: URL) -> IncomingWorkoutScreen {
        let currentPlan: TodayPlan?
        do {
            currentPlan = try todaysPlan().plan
        } catch {
            Self.log.error("Reading today's plan for a workout link failed: \(error.localizedDescription, privacy: .public)")
            currentPlan = nil
        }
        let routines: [Routine]
        do {
            routines = try self.routines.all()
        } catch {
            Self.log.error("Reading routines for a workout link failed: \(error.localizedDescription, privacy: .public)")
            routines = []
        }
        return IncomingWorkoutScreen.make(url: url, link: .configured, library: library, profile: profile,
                                          day: TodayPlan.dayKey(now()), isWorkoutRunning: session != nil,
                                          currentPlan: currentPlan, routines: routines,
                                          history: { [workouts] in (try? workouts.history(exerciseId: $0, limit: 5)) ?? [] },
                                          gym: todayGymContext())
    }

    /// Makes `plan` today's plan. False, with nothing changed, when a workout started meanwhile (the watch).
    func useSharedWorkout(_ plan: TodayPlan) -> Bool {
        guard session == nil else { return false }
        todayPlanStore.save(plan)
        NotificationCenter.default.post(name: .todayPlanReplaced, object: nil)
        return true
    }
}
