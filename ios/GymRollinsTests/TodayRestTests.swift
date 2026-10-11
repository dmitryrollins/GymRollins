import Foundation
import GymCore
import Testing
@testable import GymRollins

/// Today's "Rest today" starts the workout with that rest and survives a relaunch of the in-progress workout.
@MainActor
@Suite struct TodayRestTests {
    private func env(_ defaults: UserDefaults) throws -> AppEnvironment {
        try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]),
                           defaults: defaults)
    }

    @Test func todaysRestStartsTheWorkoutAndIsRestored() throws {
        let defaults = try #require(UserDefaults(suiteName: "TodayRestTests.\(UUID())"))
        let env = try env(defaults)
        env.startSession(routine: try env.routines.all().first, restSec: 150)
        #expect(env.session?.restSeconds == 150)
        env.endSession() // the app goes away; the active workout stays stored
        env.restoreSession()
        #expect(env.session?.restSeconds == 150, "restored with today's rest, not the profile's")
    }

    @Test func withoutTodaysRestTheProfileDefaultApplies() throws {
        let defaults = try #require(UserDefaults(suiteName: "TodayRestTests.\(UUID())"))
        let env = try env(defaults)
        env.startSession(routine: try env.routines.all().first, restSec: 150)
        env.endSession()
        try env.workouts.discardActive()
        env.startSession(routine: try env.routines.all().first)
        #expect(env.session?.restSeconds == TimeInterval(env.profile.restSec))
    }
}
