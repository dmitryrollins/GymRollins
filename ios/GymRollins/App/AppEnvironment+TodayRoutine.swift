import Foundation
import GymCore
import GymData

/// Claude's `today` changes ("train this routine on that date"): applied exactly like Today → Switch for that date.
/// The switch is local to this iPhone (UserDefaults, like a manual Switch) and never syncs; the week schedule is
/// untouched and the next day is back to normal. A workout in progress is never altered: the switch only changes
/// what Today offers next.
extension AppEnvironment {
    /// Forgets today's switched/edited plan and Claude's planned switches (a fresh, reset or wiped store).
    static func clearTodaySwitches(in defaults: UserDefaults) {
        TodayPlanStore(defaults: defaults).clear()
        PlannedSwitchStore(defaults: defaults).clear()
    }

    /// Stores each applied `today` change: today's goes into `todayPlanStore` (the watch follows), a later date's
    /// waits in `PlannedSwitchStore` until that day. Dates before today were already skipped by the validator.
    func applyDayRoutines(_ days: [PlanDayRoutine]) {
        guard !days.isEmpty else { return }
        let today = TodayPlan.dayKey(now())
        let planned = PlannedSwitchStore(defaults: defaults)
        for item in days {
            if item.day == today {
                switchToday(to: item.routineId)
            } else if item.day > today {
                planned.set(item.routineId, on: item.day)
            }
        }
    }

    /// Undo of a proposal: takes back its `today` switches that are still in place (not edited since).
    func undoDayRoutines(of proposal: Proposal) {
        let today = TodayPlan.dayKey(now())
        let planned = PlannedSwitchStore(defaults: defaults)
        let routineIds = Set(((try? routines.all()) ?? []).map(\.id))
        for change in proposal.changes where change.type == .today && proposal.appliedChangeIds.contains(change.id) {
            guard let day = change.date, let routineId = change.routineId.flatMap(UUID.init(uuidString:)) else {
                continue // a routine the proposal added: undo removed it, and a switch to it is dropped on load
            }
            if day != today {
                planned.remove(day: day, routineId: routineId)
            } else if let stored = todayPlanStore.load(day: day, routineIds: routineIds), stored.kind == .switched,
                      stored.base?.id == routineId, !stored.edited {
                todayPlanStore.clear()
            }
        }
    }

    /// Switch for today, as Today's Switch sheet does: the scheduled routine means "as scheduled".
    private func switchToday(to routineId: UUID) {
        do {
            let (plan, scheduled) = try todaysPlan()
            guard let routine = try routines.routine(routineId), !routine.paused else { return }
            if routine.id == scheduled?.id {
                todayPlanStore.clear()
            } else {
                todayPlanStore.save(plan.switched(to: routine))
            }
        } catch {
            Self.log.error("Switch today for Claude failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The switch Claude planned for `day`, taken from `PlannedSwitchStore` and stored as that day's plan (unless
    /// the day already has one). Nil when there is none, its routine is gone or paused, or it is the scheduled one.
    func takePlannedSwitch(day: String, routines all: [Routine], scheduled: Routine?) -> TodayPlan? {
        guard let routineId = PlannedSwitchStore(defaults: defaults).take(day: day),
              let routine = all.first(where: { $0.id == routineId }), !routine.paused, routine.id != scheduled?.id
        else { return nil }
        let store = TodayPlanStore(defaults: defaults) // no revision bump: this runs while the plan is being read
        guard store.load(day: day, routineIds: Set(all.map(\.id))) == nil else { return nil }
        let plan = TodayPlan.make(scheduled: scheduled, routines: all, lastDone: [:], day: day).switched(to: routine)
        store.save(plan)
        return plan
    }
}
