import Foundation
import GymCore
import Testing
@testable import GymRollins

@MainActor
@Suite struct SmokeTests {
    @Test func environmentBootsInMemoryWithSeed() throws {
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]))
        #expect(env.library.exercises.count >= 1_324)
        #expect(try env.routines.all().count == 4)
        #expect(env.profile.unit == .lb)
    }

    /// A disabled rest timer stays disabled for new (and restored) sessions without the user
    /// having to reopen the rest settings sheet.
    @Test func sessionsApplySavedRestPreference() throws {
        let defaults = try #require(UserDefaults(suiteName: "SmokeTests.\(UUID())"))
        defaults.set(false, forKey: RestPreferences.enabledKey)
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]), defaults: defaults)
        env.startSession(routine: nil)
        #expect(env.session?.restEnabled == false)
        env.endSession()
        env.restoreSession()
        #expect(env.session?.restEnabled == false)

        let fresh = try #require(UserDefaults(suiteName: "SmokeTests.\(UUID())"))
        let other = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]), defaults: fresh)
        other.startSession(routine: nil)
        #expect(other.session?.restEnabled == true)
    }

    /// Starting a session while one is in progress must never replace (and delete) the active workout.
    @Test func startSessionKeepsTheActiveWorkout() throws {
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]))
        env.startSession(routine: nil)
        let first = try #require(env.session)
        env.startSession(routine: try env.routines.all().first)
        #expect(env.session === first)
        #expect(try env.workouts.active()?.id == first.workout.id)
    }

    /// Mid-workout adds follow the saved Warm-up sets preference (not the planner's default of on).
    @Test func adHocEntryUsesSavedWarmupPreference() throws {
        let off = try #require(UserDefaults(suiteName: "SmokeTests.\(UUID())"))
        off.set(false, forKey: WarmupPreferences.autoWarmupsKey)
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-seedHistory"]), defaults: off)
        #expect(!env.adHocEntry(exerciseId: "0025").sets.contains { $0.warmup })

        let on = try #require(UserDefaults(suiteName: "SmokeTests.\(UUID())"))
        let other = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-seedHistory"]), defaults: on)
        #expect(other.adHocEntry(exerciseId: "0025").sets.contains { $0.warmup })
    }

    /// Today's and Plan's "new routine" both start with the saved progression default.
    @Test func newRoutineDraftUsesProgressionDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "SmokeTests.\(UUID())"))
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]), defaults: defaults)
        #expect(env.newRoutineDraft().policy == .double)
        defaults.set(ProgressionPolicy.linear.rawValue, forKey: ProgressionDefaultPreference.key)
        #expect(env.newRoutineDraft().policy == .linear)
    }

    @Test func launchOptionsParseDiskStoreResetAndSeedHistory() {
        let options = LaunchOptions(arguments: ["-uiTesting", "-diskStore", "-resetStore", "-seedHistory"])
        #expect(options.diskStoreURL?.lastPathComponent == "gymrollins-uitest.store")
        #expect(options.resetStore)
        #expect(options.seedHistory)
    }

    @Test func launchOptionsDefaultDiskStoreIsNil() {
        let options = LaunchOptions(arguments: ["-uiTesting"])
        #expect(options.diskStoreURL == nil)
        #expect(!options.resetStore)
        #expect(!options.seedHistory)
    }

    @Test func largeHistoryCountDefaultsAndClamps() {
        #expect(LaunchOptions(arguments: ["-seedLargeHistory"]).largeHistoryCount == 60)
        #expect(LaunchOptions(arguments: ["-seedLargeHistory", "-largeHistoryCount", "150"]).largeHistoryCount == 150)
        #expect(LaunchOptions(arguments: ["-largeHistoryCount", "0"]).largeHistoryCount == 1)
        #expect(LaunchOptions(arguments: ["-largeHistoryCount", "x"]).largeHistoryCount == 60)
    }
}
