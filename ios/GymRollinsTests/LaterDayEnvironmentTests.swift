import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// A later day on Today (owner, 2026-11-10): its plan (the owner's change, else an agent's switch, else the week), its
/// changes for that date only, Reset this day, and the change becoming today's plan on the day. The seed's Saturday
/// 26 Sep: Sunday is a rest day, Monday trains Push + Arms.
@MainActor
@Suite struct LaterDayEnvironmentTests {
    private func makeEnv() throws -> AppEnvironment {
        let defaults = try #require(UserDefaults(suiteName: "LaterDayEnvironmentTests.\(UUID())"))
        return try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]),
                                  defaults: defaults)
    }

    private func date(_ offset: Int, _ env: AppEnvironment) -> Date { TodayDay(offset: offset).date(now: env.now()) }

    private func pull(_ env: AppEnvironment) throws -> Routine {
        try #require(try env.routines.all().first { $0.name.hasPrefix("Pull") })
    }

    @Test func aRestDayIsAnEmptyPlanAndMondayIsPush() throws {
        let env = try makeEnv()
        let sunday = try env.laterDay(on: date(1, env))
        #expect(sunday.plan.kind == .empty)
        #expect(sunday.plan.exercises.isEmpty)
        #expect(sunday.scheduled == nil)
        #expect(!sunday.changed)
        let monday = try env.laterDay(on: date(2, env))
        #expect(monday.plan.title == "Push + Arms")
        #expect(monday.scheduled?.name == "Push + Arms")
        #expect(!monday.changed)
    }

    @Test func anAgentsPlannedSwitchShowsAsChangedAndStaysUntilItsDay() throws {
        let env = try makeEnv(), pull = try pull(env)
        let monday = TodayPlan.dayKey(date(2, env))
        PlannedSwitchStore(defaults: env.defaults).set(pull.id, on: monday)
        let later = try env.laterDay(on: date(2, env))
        #expect(later.plan.base?.id == pull.id)
        #expect(later.changed)
        #expect(PlannedSwitchStore(defaults: env.defaults).all()[monday] == pull.id, "reading doesn't take it")
        #expect(try env.todaysPlan().plan.title != pull.name)
    }

    @Test func theOwnersChangeIsForThatDateOnly() throws {
        let env = try makeEnv()
        let monday = try env.laterDay(on: date(2, env))
        let count = monday.plan.exercises.count
        env.laterDaySaver(on: date(2, env), scheduled: monday.scheduled?.id)
            .save(monday.plan.deleting(monday.plan.exercises[0].id))

        let changed = try env.laterDay(on: date(2, env))
        #expect(changed.changed)
        #expect(changed.plan.exercises.count == count - 1)
        #expect(env.isLaterDayChanged(TodayPlan.dayKey(date(2, env))))
        #expect(try env.laterDay(on: date(9, env)).plan.exercises.count == count, "the next Monday is as planned")
        #expect(try env.todaysPlan().plan.exercises.count == count, "today (Saturday, Push + Arms) is untouched")
    }

    @Test func theOwnersChangeReplacesAnAgentsEarlierSwitch() throws {
        let env = try makeEnv(), pull = try pull(env)
        let mondayKey = TodayPlan.dayKey(date(2, env))
        PlannedSwitchStore(defaults: env.defaults).set(pull.id, on: mondayKey)
        let monday = try env.laterDay(on: date(2, env))
        env.laterDaySaver(on: date(2, env), scheduled: monday.scheduled?.id)
            .save(monday.plan.deleting(monday.plan.exercises[0].id))
        #expect(PlannedSwitchStore(defaults: env.defaults).all()[mondayKey] == nil)
        #expect(try env.laterDay(on: date(2, env)).plan.base?.id == pull.id, "the edit was made on Pull")
    }

    @Test func anAgentsLaterChangeReplacesTheOwners() throws {
        let env = try makeEnv(), pull = try pull(env)
        let monday = try env.laterDay(on: date(2, env))
        env.laterDaySaver(on: date(2, env), scheduled: monday.scheduled?.id)
            .save(monday.plan.deleting(monday.plan.exercises[0].id))
        env.applyDayRoutines([PlanDayRoutine(changeId: "c1", day: TodayPlan.dayKey(date(2, env)), routineId: pull.id)])
        let later = try env.laterDay(on: date(2, env))
        #expect(later.plan.base?.id == pull.id)
        #expect(!later.plan.edited)
    }

    @Test func resetThisDayFollowsTheWeekAgain() throws {
        let env = try makeEnv(), pull = try pull(env)
        let mondayKey = TodayPlan.dayKey(date(2, env))
        let monday = try env.laterDay(on: date(2, env))
        env.laterDaySaver(on: date(2, env), scheduled: monday.scheduled?.id).save(monday.plan.switched(to: pull))
        env.resetLaterDay(mondayKey)
        let reset = try env.laterDay(on: date(2, env))
        #expect(reset.plan.title == "Push + Arms")
        #expect(!reset.changed)
        #expect(!env.isLaterDayChanged(mondayKey))
    }

    @Test func restOnATrainingDateIsKept_andAnEmptyRestDayIsNotAChange() throws {
        let env = try makeEnv()
        let monday = try env.laterDay(on: date(2, env))
        env.laterDaySaver(on: date(2, env), scheduled: monday.scheduled?.id).save(monday.plan.switched(to: nil))
        let rested = try env.laterDay(on: date(2, env))
        #expect(rested.changed)
        #expect(rested.plan.kind == .empty)

        let sunday = try env.laterDay(on: date(1, env))
        let saver = env.laterDaySaver(on: date(1, env), scheduled: nil)
        saver.save(sunday.plan)
        #expect(!env.isLaterDayChanged(TodayPlan.dayKey(date(1, env))), "nothing on a rest day is no change")
    }

    @Test func onTheDayTheChangeBecomesTodaysPlan() throws {
        let env = try makeEnv()
        let monday = try env.laterDay(on: date(2, env))
        let count = monday.plan.exercises.count
        env.laterDaySaver(on: date(2, env), scheduled: monday.scheduled?.id)
            .save(monday.plan.deleting(monday.plan.exercises[0].id))

        let onTheDay = try env.todaysPlan(at: date(2, env)).plan
        #expect(onTheDay.exercises.count == count - 1)
        #expect(LaterDayPlanStore(defaults: env.defaults).days().isEmpty, "taken")
        #expect(try env.todaysPlan(at: date(2, env)).plan.exercises.count == count - 1, "now today's stored plan")
    }

    @Test func aChangeWhoseWorkoutIsGoneIsDroppedWhenRead() throws {
        let env = try makeEnv(), pull = try pull(env)
        let mondayKey = TodayPlan.dayKey(date(2, env))
        let monday = try env.laterDay(on: date(2, env))
        env.laterDaySaver(on: date(2, env), scheduled: monday.scheduled?.id).save(monday.plan.switched(to: pull))
        try env.routines.delete(pull.id)
        #expect(!(try env.laterDay(on: date(2, env)).changed))
        #expect(!env.isLaterDayChanged(mondayKey))
    }

    @Test func wipingTheSwitchesClearsLaterDays() throws {
        let env = try makeEnv(), pull = try pull(env)
        let monday = try env.laterDay(on: date(2, env))
        env.laterDaySaver(on: date(2, env), scheduled: monday.scheduled?.id).save(monday.plan.switched(to: pull))
        AppEnvironment.clearTodaySwitches(in: env.defaults)
        #expect(LaterDayPlanStore(defaults: env.defaults).days().isEmpty)
    }
}
