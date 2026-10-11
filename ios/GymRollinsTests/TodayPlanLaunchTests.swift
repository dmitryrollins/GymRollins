import Foundation
import GymCore
import Testing
@testable import GymRollins

/// Today's switched/edited plan lives in UserDefaults, but belongs to the data it was made from. A launch on a fresh
/// store (in-memory UI tests, `-resetStore`) or a local-data wipe must not bring back a plan from an earlier store:
/// that is what made `WorkoutFlowUITests.testEditConsecutiveFieldsWithoutLeavingScreen` start TodayFlexUITests'
/// leftover "Empty workout + Chest Dip" instead of the scheduled Push day.
@MainActor
@Suite struct TodayPlanLaunchTests {
    private let day = "2026-09-26"
    private let args = ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]

    private func defaultsWithLeftoverPlan() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "TodayPlanLaunchTests.\(UUID())"))
        let leftover = TodayPlan(day: day, kind: .empty, base: nil,
                                 exercises: [RoutineExercise(exerciseId: "0251", sets: 3, reps: 10)], edited: true)
        TodayPlanStore(defaults: defaults).save(leftover)
        #expect(TodayPlanStore(defaults: defaults).load(day: day, routineIds: []) != nil)
        return defaults
    }

    @Test func aFreshInMemoryStoreForgetsAnOldTodayPlan() throws {
        let defaults = try defaultsWithLeftoverPlan()
        _ = try AppEnvironment(options: LaunchOptions(arguments: args), defaults: defaults)
        #expect(TodayPlanStore(defaults: defaults).load(day: day, routineIds: []) == nil)
    }

    @Test func onlyAFreshStoreForgetsTodaysPlan() {
        #expect(AppEnvironment.startsWithFreshStore(LaunchOptions(arguments: ["-uiTesting"])))
        #expect(AppEnvironment.startsWithFreshStore(LaunchOptions(arguments: ["-uiTesting", "-diskStore", "-resetStore"])))
        #expect(!AppEnvironment.startsWithFreshStore(LaunchOptions(arguments: ["-uiTesting", "-diskStore"])),
                "a relaunch on the same disk store keeps today's plan")
        #expect(!AppEnvironment.startsWithFreshStore(LaunchOptions(arguments: [])), "a normal launch keeps it")
    }

    @Test func erasingLocalDataForgetsTodaysPlan() throws {
        let defaults = try #require(UserDefaults(suiteName: "TodayPlanLaunchTests.\(UUID())"))
        let env = try AppEnvironment(options: LaunchOptions(arguments: args), defaults: defaults)
        TodayPlanStore(defaults: defaults).save(TodayPlan(day: day, kind: .empty, base: nil, exercises: [], edited: false))
        #expect(TodayPlanStore(defaults: defaults).load(day: day, routineIds: []) != nil)
        try env.eraseAllLocalData()
        #expect(TodayPlanStore(defaults: defaults).load(day: day, routineIds: []) == nil)
    }
}
