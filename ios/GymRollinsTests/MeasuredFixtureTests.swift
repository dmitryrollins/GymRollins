import Foundation
import GymCore
import GymHealth
import Testing
@testable import GymRollins

/// Plan 40's UI-test fixture: with `-fakeHealth`, Health holds the GymRollins watch app's copy of `-seedHistory`'s
/// Sat 19 Sep workout; `-fakeHealthNoWatchCopy` leaves plan 39's attached recording; Sat 12 Sep has nothing there.
/// `-fakeHealthEffortUnasked` leaves the effort types to the Allow pill's ask.
@MainActor
@Suite struct MeasuredFixtureTests {
    private func makeEnv(_ extra: [String] = []) async throws -> AppEnvironment {
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fakeHealth", "-seedHistory",
                                                                       "-fixedNow", "2026-09-26T09:00:00Z"] + extra))
        #expect(await env.health.enable())
        return env
    }

    /// The newest seeded workout (19 Sep) and the older one (12 Sep).
    private func seeded(_ env: AppEnvironment) throws -> (sat19: Workout, sat12: Workout) {
        let recent = try env.workouts.recent(limit: 2)
        return (try #require(recent.first), try #require(recent.last))
    }

    @Test func the19SepWorkoutHasTheWatchsCopy() async throws {
        let env = try await makeEnv()
        let summary = await env.measuredSummary(for: try seeded(env).sat19)
        #expect(summary.source == .watch)
        #expect(summary.workoutTime == 3_500)
        #expect(summary.activeKcal == 412 && summary.totalKcal == 489)
        #expect(summary.avgHr == 128 && summary.maxHr == 162 && summary.heartRate.count == 12)
        #expect(summary.postWorkout.map(\.bpm) == [141, 132, 124])
        #expect(summary.lastPostHr == 124 && summary.postHr == 132)
        #expect(summary.effort == nil)
    }

    @Test func withoutTheCopyTheAttachedRecordingShows() async throws {
        let env = try await makeEnv(["-fakeHealthNoWatchCopy"])
        let summary = await env.measuredSummary(for: try seeded(env).sat19)
        #expect(summary.source == .attached(sourceName: "Apple Watch"))
        #expect(summary.workoutTime == 3_180)
        #expect(summary.activeKcal == 412 && summary.totalKcal == nil)
        #expect(summary.avgHr == 128 && summary.maxHr == 162 && summary.heartRate.isEmpty)
    }

    @Test func the12SepWorkoutIsTheEstimate() async throws {
        let env = try await makeEnv()
        let summary = await env.measuredSummary(for: try seeded(env).sat12)
        #expect(summary.source == .estimate)
        #expect(summary.estimatedKcal != nil && summary.heartRate.isEmpty && summary.avgHr == nil)
    }

    /// `-fakeHealthEffortUnasked`: Health turned on before the effort types existed (an early build), so the
    /// detail's Allow pill shows until its ask runs; then a rating reaches Health.
    @Test func withTheEffortTypesUnaskedTheAllowPillAsksThem() async throws {
        let env = try await makeEnv(["-fakeHealthEffortUnasked"])
        let sat19 = try seeded(env).sat19
        _ = await env.measuredSummary(for: sat19) // the read checks the effort types
        #expect(env.health.effortNeedsAsking)
        await env.allowHealthEffort()
        #expect(!env.health.effortNeedsAsking)
        #expect(await env.rateEffort(6, for: sat19) == .saved)
    }

    @Test func theReadingsAreTheDocumentedOnes() {
        #expect(DebugMeasuredSeed.workoutBpm.count == 12)
        #expect(DebugMeasuredSeed.workoutBpm.reduce(0, +) / 12 == 128)
        #expect(DebugMeasuredSeed.workoutBpm.max() == 162 && DebugMeasuredSeed.workoutBpm.min() == 110)
        #expect(DebugMeasuredSeed.firstReading + 11 * DebugMeasuredSeed.readingEvery < 3_500, "all inside 58:20")
        #expect(DebugMeasuredSeed.postWorkout.map(\.seconds).allSatisfy { $0 <= WorkoutMeasuredRules.postWindow })
        #expect(DebugMeasuredSeed.postWorkout.last?.bpm == 124)
    }
}
