import Foundation
import GymCore
import GymData
import GymWatchLink

/// Apple Watch wiring (plan 17): what the watch is sent, how its commands reach the session, and Today's plan (shared
/// by the Today screen and the watch's "Start today's workout").
extension AppEnvironment {
    // MARK: Today's plan

    /// Today's stored plan; every save/clear bumps `todayPlanRevision` (the watch follows today-only changes).
    var todayPlanStore: TodayPlanStore {
        TodayPlanStore(defaults: defaults) { [weak self] in self?.todayPlanChanged() }
    }

    /// Today's workout before it starts (scheduled, rest-day suggestion, switched or empty), plus the routine scheduled
    /// for today (nil when none, or paused).
    func todaysPlan() throws -> (plan: TodayPlan, scheduled: Routine?) { try todaysPlan(at: now()) }

    /// `todaysPlan()` for the day `date` falls on (a switch Claude planned for that day becomes its stored plan).
    func todaysPlan(at date: Date) throws -> (plan: TodayPlan, scheduled: Routine?) {
        let schedule = try routines.schedule()
        let routine = try schedule.routineId(on: date).flatMap { try routines.routine($0) }
        let scheduled = routine?.paused == true ? nil : routine
        let all = try routines.all()
        let day = TodayPlan.dayKey(date)
        let planned = takePlannedSwitch(day: day, routines: all, scheduled: scheduled)
        let plan = TodayPlanStore(defaults: defaults).load(day: day, routines: all, scheduled: scheduled?.id)
            ?? planned
            ?? TodayPlan.make(scheduled: scheduled, routines: all, lastDone: lastDoneByRoutine(), day: day)
        return (plan, scheduled)
    }

    /// Whether Today offers Start for `plan` (the same rule as its bottom bar).
    func canStart(_ plan: TodayPlan) -> Bool {
        !plan.exercises.isEmpty || (plan.kind == .empty && hasAnyRoutine)
    }

    /// Starts today's workout like Today's Start button (the watch's "Start today's workout"). False when a workout is
    /// already running or there is nothing to start.
    @discardableResult
    func startTodaysWorkout() -> Bool {
        guard session == nil else { return false }
        do {
            let plan = try todaysPlan().plan
            guard canStart(plan) else { return false }
            startSession(routine: plan.routineToStart, setOverrides: plan.setOverrides, restSec: plan.restSec)
            todayPlanStore.clear()
            return session != nil
        } catch {
            Self.log.error("Start today's workout failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// When each routine was last trained (for the rest-day suggestion).
    func lastDoneByRoutine() -> [UUID: Date] {
        let recent = (try? workouts.recent(limit: 60)) ?? []
        return recent.reduce(into: [:]) { result, workout in
            guard let id = workout.routineId else { return }
            result[id] = max(result[id] ?? .distantPast, workout.startedAt)
        }
    }

    // MARK: Watch state

    /// What the watch shows now. Reads observable state only (session, profile, library, Health ledger, revisions), so
    /// `WatchSyncController` re-sends when any of it changes.
    var watchSnapshot: WatchSyncController.Snapshot {
        let library = self.library
        let health = self.health
        let workout = WatchStateMapper.workout(session: session, now: now(), profile: profile,
                                               exercise: { library.exercise($0) },
                                               watchRecordsHealth: { health.isClaimedByWatch($0) })
        return WatchSyncController.Snapshot(workout: workout, today: workout == nil ? watchToday : nil,
                                            healthEnabled: health.isEnabled)
    }

    private var watchToday: WatchToday? {
        _ = planRevision // re-send when the plan changes
        _ = todayPlanRevision // …or today's plan is switched or edited for today only
        _ = dataRevision // …or a workout is saved (rest-day suggestion)
        guard let plan = try? todaysPlan().plan else { return nil }
        return WatchToday(title: plan.title, canStart: canStart(plan))
    }

    /// How the workout the watch last saw running ended: finished (saved) or discarded. A discarded one drops the
    /// watch's Health claim; a finished one keeps it, so only the watch writes it to Health.
    func endedWatchWorkout(_ id: UUID) -> WatchEndedWorkout {
        let saved = try? workouts.workout(id)
        guard let saved, let endedAt = saved.endedAt else {
            health.dropWatchClaim(id)
            return WatchEndedWorkout(workoutId: id, endedAt: now(), finished: false, watchRecordsHealth: false)
        }
        // `endedAt` may be the last set, long before Finish was tapped (IdleFinish); the watch's window runs from now.
        return WatchEndedWorkout(workoutId: id, endedAt: endedAt, finished: true,
                                 watchRecordsHealth: health.isClaimedByWatch(id), finishedAt: now())
    }

    /// The handler's hooks into this environment.
    var watchCommandHooks: WatchCommandHandler.Hooks {
        WatchCommandHandler.Hooks(
            session: { [weak self] in self?.session },
            exercise: { [weak self] in self?.library.exercise($0) },
            healthEnabled: { [weak self] in self?.health.isEnabled ?? false },
            startToday: { [weak self] in self?.startTodaysWorkout() ?? false },
            acceptClaim: { [weak self] in self?.health.acceptWatchClaim($0) },
            recorded: { [weak self] in
                // Taken however late; an export run then keeps the watch's copy if the phone already wrote one.
                self?.health.markRecordedByWatch($0)
                self?.exportToHealth()
            })
    }
}
