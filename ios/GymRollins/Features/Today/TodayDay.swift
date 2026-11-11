import Foundation
import GymCore
import GymData

/// The day Today shows (owner, 2026-11-09): today, or a later day previewed read-only. Swiping and the date picker
/// move it; a day before today can't be reached, so past workouts stay in Log.
struct TodayDay: Equatable {
    /// Days after today: 0 is today.
    let offset: Int

    static let today = TodayDay(offset: 0)

    init(offset: Int) { self.offset = max(0, offset) }

    /// The day `date` falls on, counted from `now`'s day; a date before today is today.
    init(date: Date, now: Date, calendar: Calendar = .current) {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        self.init(offset: days)
    }

    var isToday: Bool { offset == 0 }
    var next: TodayDay { TodayDay(offset: offset + 1) }
    var previous: TodayDay { TodayDay(offset: offset - 1) }

    /// Midday of the day, so a clock change can't move it to the day before.
    func date(now: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
        return calendar.date(byAdding: .hour, value: 12, to: day) ?? day
    }

    /// "Today", "Tomorrow", a weekday in the coming week ("Wednesday"), then a date ("3 Oct").
    func title(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2...6: return date(now: now, calendar: calendar).formatted(style.weekday(.wide))
        default: return date(now: now, calendar: calendar).formatted(style.day().month(.abbreviated))
        }
    }
}

/// What a later day trains, as Today shows it: an agent's one-day change for that date (`PlannedSwitchStore`) wins
/// over the week schedule, under the rules Today applies on the day (`takePlannedSwitch`). Nil is a rest day.
enum DayPreview {
    static func plan(day: String, scheduled: Routine?, routines: [Routine], planned: UUID?) -> TodayPlan? {
        let base = TodayPlan.make(scheduled: scheduled, routines: [], lastDone: [:], day: day)
        if let planned, let routine = routines.first(where: { $0.id == planned }), !routine.paused,
           routine.id != scheduled?.id {
            return base.switched(to: routine)
        }
        return scheduled == nil ? nil : base
    }

    /// A later day's model, made like today's (`TodayModel.make`): a rest day reads "Rest day", and a date the owner
    /// or an agent changed says "changed for this day" (never "edited for today").
    static func laterDay(_ model: TodayModel, plan: TodayPlan, changed: Bool) -> TodayModel {
        if plan.kind == .empty && plan.exercises.isEmpty {
            return TodayModel(routineId: nil, title: "Rest day",
                              summary: changed ? "Changed for this day" : "Recover and eat well", rows: [])
        }
        let count = model.rows.count == 1 ? "1 exercise" : "\(model.rows.count) exercises"
        return TodayModel(routineId: model.routineId, title: model.title,
                          summary: changed ? "\(count) \u{00B7} changed for this day" : count, rows: model.rows,
                          gymNote: model.gymNote)
    }
}
