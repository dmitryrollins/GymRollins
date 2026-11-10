import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@MainActor
@Suite struct DayPreviewEnvironmentTests {
    private func makeEnv() throws -> AppEnvironment {
        let defaults = try #require(UserDefaults(suiteName: "DayPreviewEnvironmentTests.\(UUID())"))
        return try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]),
                                  defaults: defaults)
    }

    private func day(_ offset: Int, _ env: AppEnvironment) -> Date { TodayDay(offset: offset).date(now: env.now()) }

    @Test func tomorrowIsRestAndMondayIsPush() throws {
        let env = try makeEnv()
        #expect(try env.previewPlan(on: day(1, env)) == nil)
        #expect(try env.previewPlan(on: day(2, env))?.title == "Push + Arms")
    }

    @Test func previewingAnAgentsPlannedDayLeavesItForThatDay() throws {
        let env = try makeEnv()
        let pull = try #require(try env.routines.all().first { $0.name.hasPrefix("Pull") })
        let monday = TodayPlan.dayKey(day(2, env))
        PlannedSwitchStore(defaults: env.defaults).set(pull.id, on: monday)
        #expect(try env.previewPlan(on: day(2, env))?.base?.id == pull.id)
        #expect(try env.previewPlan(on: day(2, env))?.base?.id == pull.id) // still there: preview doesn't take it
        #expect(PlannedSwitchStore(defaults: env.defaults).all()[monday] == pull.id)
        #expect(try env.todaysPlan().plan.title != pull.name) // today's plan is untouched
    }
}
