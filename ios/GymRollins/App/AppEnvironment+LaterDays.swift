import Foundation
import GymCore
import GymData

/// Later days on Today (owner, 2026-11-10): a later day is edited like today, for that date only. The owner's change
/// waits in `LaterDayPlanStore` until the day, when it becomes today's stored plan. An agent's planned switch for a
/// date (`PlannedSwitchStore`) and the owner's change replace each other: the newer one wins.
extension AppEnvironment {
    /// The later day Today shows.
    struct LaterDay {
        let plan: TodayPlan
        /// The workout the week has on that day (nil: a rest day, or its workout is paused).
        let scheduled: Routine?
        /// The owner or an agent changed this date: Today says so and offers Reset this day.
        let changed: Bool
    }

    /// The later day `date` falls on: the owner's change for it, else an agent's planned switch, else the week (a
    /// rest day is an empty plan), at the current gym. A change that no longer applies is removed; nothing is taken.
    func laterDay(on date: Date) throws -> LaterDay {
        let all = try routines.all()
        let routine = try routines.schedule().routineId(on: date).flatMap { id in all.first { $0.id == id } }
        let scheduled = routine?.paused == true ? nil : routine
        let day = TodayPlan.dayKey(date)
        let store = LaterDayPlanStore(defaults: defaults)
        if let stored = store.plan(day: day, routines: all, scheduled: scheduled?.id) {
            return LaterDay(plan: stored.adapted(by: gymAdapter()), scheduled: scheduled, changed: true)
        }
        if store.days().contains(day) { store.remove(day: day) }
        let preview = DayPreview.plan(day: day, scheduled: scheduled, routines: all,
                                      planned: PlannedSwitchStore(defaults: defaults).all()[day])
        let plan = preview ?? TodayPlan(day: day, kind: .empty, base: nil, exercises: [], edited: false)
        return LaterDay(plan: plan.adapted(by: gymAdapter()), scheduled: scheduled, changed: preview?.kind == .switched)
    }

    /// Where Today's editor keeps changes to the later day `date` falls on.
    func laterDaySaver(on date: Date, scheduled: UUID?) -> LaterDayPlanSaver {
        LaterDayPlanSaver(day: TodayPlan.dayKey(date), scheduled: scheduled, defaults: defaults)
    }

    /// Whether the owner or an agent changed the later day `day` (yyyy-MM-dd).
    func isLaterDayChanged(_ day: String) -> Bool {
        LaterDayPlanStore(defaults: defaults).days().contains(day)
            || PlannedSwitchStore(defaults: defaults).all()[day] != nil
    }

    /// Reset this day: the date follows the week again (the owner's change and an agent's switch for it go).
    func resetLaterDay(_ day: String) {
        LaterDayPlanStore(defaults: defaults).remove(day: day)
        PlannedSwitchStore(defaults: defaults).remove(day: day)
    }

    /// On the day itself: the owner's change for it, taken from `LaterDayPlanStore` and stored as today's plan (unless
    /// today already has one). Nil when there is none or it no longer applies.
    func takeLaterDayPlan(day: String, routines all: [Routine], scheduled: Routine?) -> TodayPlan? {
        guard let plan = LaterDayPlanStore(defaults: defaults).take(day: day),
              plan.base.map({ base in all.contains { $0.id == base.id } }) ?? true,
              let current = TodayPlanStore.current(plan, routines: all, scheduled: scheduled?.id) else { return nil }
        let store = TodayPlanStore(defaults: defaults) // no revision bump: this runs while the plan is being read
        guard store.load(day: day, routineIds: Set(all.map(\.id))) == nil else { return nil }
        store.save(current)
        return current
    }
}

/// Where Today's editor keeps a later day's changes: `LaterDayPlanStore`. Saving also drops an agent's planned switch
/// for that date (the owner's change is the newer one); a plan that is the day as planned is no change.
struct LaterDayPlanSaver: TodayPlanSaving {
    let day: String
    /// The workout the week has on that day (nil: a rest day).
    let scheduled: UUID?
    let defaults: UserDefaults

    func save(_ plan: TodayPlan) {
        PlannedSwitchStore(defaults: defaults).remove(day: day)
        let store = LaterDayPlanStore(defaults: defaults)
        let asPlanned = !plan.hasTodayChanges || (scheduled == nil && plan.kind == .empty && plan.exercises.isEmpty)
        if asPlanned { store.remove(day: day) } else { store.save(plan) }
    }

    func clear() {
        PlannedSwitchStore(defaults: defaults).remove(day: day)
        LaterDayPlanStore(defaults: defaults).remove(day: day)
    }
}
