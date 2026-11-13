import Foundation
import GymCore
import GymData

/// Changes to the week (owner, 2026-11-10), shared by My Plan's day editor and Today's Switch and Save Changes.
extension AppEnvironment {
    /// The days `routineId` is on besides `weekday`, Monday first: the days a change to it from that day also reaches.
    func otherDays(of routineId: UUID, besides weekday: Int) throws -> [Int] {
        WeekPlan.weekdays(of: routineId, in: try routines.schedule()).filter { $0 != weekday }
    }

    /// Saves an edited workout for every day it's on, or (`onlyOn`) as a copy that takes over that one weekday.
    /// Returns the workout that was saved. Throws `GymDataError.invalidInput` for a name or size the server rejects.
    @discardableResult
    func saveWorkout(_ routine: Routine, onlyOn weekday: Int? = nil) throws -> Routine {
        guard let weekday else {
            try routines.upsert(routine)
            planChanged()
            return routine
        }
        let copy = WeekPlan.copy(of: routine, for: weekday)
        try routines.upsert(copy)
        do {
            try routines.setSchedule(weekday: weekday, routineId: copy.id)
        } catch {
            try? routines.delete(copy.id) // a copy that isn't on its day is taken back
            throw error
        }
        planChanged()
        return copy
    }

    /// Every `weekday` trains `routineId` from now on (nil: a rest day).
    func schedule(every weekday: Int, _ routineId: UUID?) throws {
        try routines.setSchedule(weekday: weekday, routineId: routineId)
        planChanged()
    }
}
