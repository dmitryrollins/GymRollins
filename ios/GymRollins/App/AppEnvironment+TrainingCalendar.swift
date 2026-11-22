import Foundation
import GymCore
import GymData

extension AppEnvironment {
    /// The calendar's days as they stand, in the order Today reads a day: today's stored plan, the owner's change for
    /// a date, an agent's planned switch, then the week; and the finished workouts. Unlike `laterDay(on:)` and
    /// `todaysPlan()`, it takes and removes nothing. Every day is empty when the store can't be read.
    func trainingCalendar(calendar: Calendar = .current) -> TrainingCalendar {
        let today = TodayPlan.dayKey(now(), calendar: calendar)
        do {
            let all = try routines.all()
            let schedule = try routines.schedule()
            let doneDays = Set(try workouts.finishedStartDates().map { TodayPlan.dayKey($0, calendar: calendar) })
            let stored = TodayPlanStore(defaults: defaults)
            let changes = LaterDayPlanStore(defaults: defaults)
            let switches = PlannedSwitchStore(defaults: defaults).all()
            return TrainingCalendar(doneDays: doneDays, today: today, calendar: calendar) { date in
                let day = TodayPlan.dayKey(date, calendar: calendar)
                let routine = schedule.routineId(on: date, calendar: calendar).flatMap { id in all.first { $0.id == id } }
                let scheduled = routine?.paused == true ? nil : routine
                if day == today, let plan = stored.load(day: day, routines: all, scheduled: scheduled?.id) {
                    return plan.hasWorkout
                }
                if let plan = changes.plan(day: day, routines: all, scheduled: scheduled?.id) { return plan.hasWorkout }
                if let id = switches[day], all.contains(where: { $0.id == id && !$0.paused }) { return true }
                return scheduled != nil
            }
        } catch {
            Self.log.error("Calendar read failed: \(error.localizedDescription, privacy: .public)")
            return TrainingCalendar(doneDays: [], today: today, calendar: calendar) { _ in false }
        }
    }
}

private extension TodayPlan {
    /// Something to train: not an empty day, and not just a rest day's optional suggestion left as offered.
    var hasWorkout: Bool { !exercises.isEmpty && !(kind == .restDaySuggestion && !edited) }
}
