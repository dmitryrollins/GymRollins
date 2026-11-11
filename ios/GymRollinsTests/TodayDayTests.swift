import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@Suite struct TodayDayTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()
    private let locale = Locale(identifier: "en_GB")
    /// Saturday 26 Sep 2026, 09:00 London.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 9))! }

    @Test func offsetsNeverGoBeforeToday() {
        #expect(TodayDay.today.previous == .today)
        #expect(TodayDay(offset: -3) == .today)
        #expect(TodayDay.today.next.offset == 1)
        #expect(TodayDay.today.next.previous == .today)
    }

    @Test func aDateMapsToItsDayFromToday() {
        let tuesday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 23))!
        #expect(TodayDay(date: tuesday, now: now, calendar: calendar).offset == 3)
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!
        #expect(TodayDay(date: yesterday, now: now, calendar: calendar) == .today)
    }

    @Test func theDayKeepsItsCalendarDayAcrossTheClockChange() {
        // UK clocks go back on Sun 25 Oct 2026; 30 days from 26 Sep is Mon 26 Oct.
        let day = TodayDay(offset: 30).date(now: now, calendar: calendar)
        #expect(TodayPlan.dayKey(day, calendar: calendar) == "2026-10-26")
    }

    @Test func titles() {
        #expect(TodayDay.today.title(now: now, calendar: calendar, locale: locale) == "Today")
        #expect(TodayDay(offset: 1).title(now: now, calendar: calendar, locale: locale) == "Tomorrow")
        #expect(TodayDay(offset: 2).title(now: now, calendar: calendar, locale: locale) == "Monday")
        #expect(TodayDay(offset: 6).title(now: now, calendar: calendar, locale: locale) == "Friday")
        #expect(TodayDay(offset: 7).title(now: now, calendar: calendar, locale: locale) == "3 Oct")
    }

    // MARK: DayPreview.plan

    private let push = Routine(name: "Push", exercises: [])
    private let pull = Routine(name: "Pull", exercises: [])
    private let paused = Routine(name: "Legs", paused: true, exercises: [])

    @Test func aRestDayWithNothingPlannedIsNil() {
        #expect(DayPreview.plan(day: "2026-09-27", scheduled: nil, routines: [push], planned: nil) == nil)
    }

    @Test func theScheduledRoutineShows() {
        let plan = DayPreview.plan(day: "2026-09-28", scheduled: push, routines: [push, pull], planned: nil)
        #expect(plan?.kind == .scheduled)
        #expect(plan?.base?.id == push.id)
    }

    @Test func anAgentsOneDayChangeWins() {
        let plan = DayPreview.plan(day: "2026-09-28", scheduled: push, routines: [push, pull], planned: pull.id)
        #expect(plan?.kind == .switched)
        #expect(plan?.base?.id == pull.id)
        let onRest = DayPreview.plan(day: "2026-09-27", scheduled: nil, routines: [push, pull], planned: pull.id)
        #expect(onRest?.base?.id == pull.id)
    }

    @Test func aPlannedChangeTodayWouldIgnoreIsIgnored() {
        // Paused, deleted, or the scheduled routine itself: the same rules as takePlannedSwitch.
        #expect(DayPreview.plan(day: "d", scheduled: push, routines: [push, paused], planned: paused.id)?.kind == .scheduled)
        #expect(DayPreview.plan(day: "d", scheduled: push, routines: [push], planned: UUID())?.kind == .scheduled)
        #expect(DayPreview.plan(day: "d", scheduled: push, routines: [push], planned: push.id)?.kind == .scheduled)
        #expect(DayPreview.plan(day: "d", scheduled: nil, routines: [paused], planned: paused.id) == nil)
    }

    private func model(_ plan: TodayPlan) -> TodayModel {
        TodayModel.make(plan: plan, profile: Profile(), library: ExerciseLibrary(exercises: []), history: { _ in [] })
    }

    @Test func aLaterRestDaySaysRest() {
        let rest = TodayPlan(day: "2026-09-27", kind: .empty, base: nil, exercises: [], edited: false)
        let model = DayPreview.laterDay(model(rest), plan: rest, changed: false)
        #expect(model.title == "Rest day")
        #expect(model.summary == "Recover and eat well")
        #expect(model.rows.isEmpty)
        #expect(DayPreview.laterDay(self.model(rest), plan: rest, changed: true).summary == "Changed for this day")
    }

    @Test func aChangedLaterDaySaysSoInsteadOfEditedForToday() {
        let bench = Routine(name: "Push", exercises: [RoutineExercise(exerciseId: "0025", sets: 3, reps: 8),
                                                      RoutineExercise(exerciseId: "0027", sets: 3, reps: 8)])
        let edited = TodayPlan.make(scheduled: bench, routines: [bench], lastDone: [:], day: "2026-09-28")
            .deleting(bench.exercises[0].id)
        let changed = DayPreview.laterDay(model(edited), plan: edited, changed: true)
        #expect(changed.title == "Push")
        #expect(changed.summary == "1 exercise \u{00B7} changed for this day")
        let planned = TodayPlan.make(scheduled: bench, routines: [bench], lastDone: [:], day: "2026-09-28")
        #expect(DayPreview.laterDay(model(planned), plan: planned, changed: false).summary == "2 exercises")
    }
}
