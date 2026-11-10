import Foundation
import GymCore
import GymData

extension AppEnvironment {
    /// A later day's plan for Today's preview, at the current gym (like `todaysPlan(at:)`). Read-only: an agent's
    /// planned switch stays in `PlannedSwitchStore` until its day, and today's stored plan is never read or written.
    func previewPlan(on date: Date) throws -> TodayPlan? {
        let all = try routines.all()
        let scheduled = try routines.schedule().routineId(on: date).flatMap { id in all.first { $0.id == id } }
        let day = TodayPlan.dayKey(date)
        return DayPreview.plan(day: day, scheduled: scheduled?.paused == true ? nil : scheduled, routines: all,
                               planned: PlannedSwitchStore(defaults: defaults).all()[day])?
            .adapted(by: gymAdapter())
    }
}
