import Foundation
import GymCore
import GymData

/// The week as the plan (owner, 2026-11-10): day names (ISO weekday 1 = Monday … 7 = Sunday), the days a workout is
/// on, a day row's exercise line, and the copy that lets one day change on its own.
enum WeekPlan {
    /// "Monday" for 1 … "Sunday" for 7.
    static func dayName(_ weekday: Int, calendar: Calendar = .current) -> String {
        calendar.standaloneWeekdaySymbols[weekday % 7]
    }

    /// "Mon" for 1 … "Sun" for 7.
    static func shortDayName(_ weekday: Int, calendar: Calendar = .current) -> String {
        calendar.shortStandaloneWeekdaySymbols[weekday % 7]
    }

    /// "Monday and Saturday", Monday first, in the calendar's language.
    static func dayList(_ weekdays: [Int], calendar: Calendar = .current) -> String {
        let formatter = ListFormatter()
        formatter.locale = calendar.locale ?? .current
        return formatter.string(from: weekdays.sorted().map { dayName($0, calendar: calendar) }) ?? ""
    }

    /// The days `routineId` is on, Monday first.
    static func weekdays(of routineId: UUID, in schedule: WeekSchedule) -> [Int] {
        schedule.days.filter { $0.value == routineId }.map(\.key).sorted()
    }

    /// A day row's exercises: "Bench Press · Dips · Curl +2".
    static func exerciseLine(_ names: [String]) -> String {
        let shown = names.prefix(3)
        let more = names.count - shown.count
        return shown.joined(separator: " \u{00B7} ") + (more > 0 ? " +\(more)" : "")
    }

    /// `routine` for one day only: a new workout with new ids (an item id belongs to one workout), named
    /// "Push + Arms (Mon)" within the name limit.
    static func copy(of routine: Routine, for weekday: Int, calendar: Calendar = .current) -> Routine {
        let suffix = " (\(shortDayName(weekday, calendar: calendar)))"
        let name = String(routine.name.prefix(DomainLimits.routineNameMax - suffix.count)) + suffix
        let items = routine.exercises.map { item in
            RoutineExercise(exerciseId: item.exerciseId, sets: item.sets, reps: item.reps, repsMin: item.repsMin,
                            sec: item.sec, weightKg: item.weightKg, mode: item.mode, policy: item.policy,
                            incKg: item.incKg, supersetGroup: item.supersetGroup, weightSetAt: item.weightSetAt)
        }
        return Routine(name: name, emoji: routine.emoji, policy: routine.policy, exercises: items)
    }
}
