import Foundation
import GymCore
import GymData
import GymHealth
import Testing
@testable import GymRollins

/// Plan 39 in the app. With `-fakeHealth`, the walk, the strength recording, the indoor ride and the 7 days come in
/// when Health is turned on. The rules resolve them against the workouts on this iPhone, and the two switches hide
/// what they read.
@MainActor
@Suite struct HealthActivityEnvironmentTests {
    private func makeEnv(_ extra: [String] = []) throws -> AppEnvironment {
        try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fakeHealth", "-fixedNow",
                                                             "2026-09-26T09:00:00Z"] + extra))
    }

    @Test func turningHealthOnBringsInTheWalkAndSevenDays() async throws {
        let env = try makeEnv()
        let revision = env.dataRevision
        #expect(await env.health.enable())
        #expect(env.resolvedActivities().shown.map(\.id).contains(FakeHealthStore.uiTestWalkId))
        #expect(env.recentActivityDays().count == 7)
        #expect(env.dataRevision > revision, "screens reload")
        #expect(try env.syncStore.dirtyHealthActivities().count == 3, "all three go to the cloud")
    }

    @Test func theSeededRideHasPowerCadenceAndTotalCalories() async throws {
        let env = try makeEnv()
        _ = await env.health.enable()
        let ride = try #require(env.resolvedActivities().shown.first { $0.id == AppEnvironment.uiTestRideId })
        #expect(ride.kind == "cycling" && ride.sourceName == "LifeFitness" && ride.fromWatch)
        #expect(ride.durationS == 308 && ride.distanceM == 2_260 && ride.kcal == 40 && ride.totalKcal == 48)
        #expect(ride.avgPowerW == 138 && ride.avgCadenceRpm == 62 && ride.avgHr == 128 && ride.maxHr == 151)
        #expect(!ride.countsAsWorkout, "under 10 minutes: the streak and the weekly goal stay as they were")
    }

    @Test func theDetailSaysWhenHealthRemovedTheWorkout() async throws {
        let env = try makeEnv()
        _ = await env.health.enable()
        let walk = FakeHealthStore.uiTestWalkId
        guard case .shown(let shown) = env.outsideWorkout(walk) else {
            Issue.record("the walk isn't shown")
            return
        }
        #expect(shown.id == walk)
        try env.activities.delete(walk)
        #expect(env.outsideWorkout(walk) == .removed, "a tombstone")
        #expect(env.outsideWorkout(UUID()) == .removed, "no row at all")
    }

    @Test func theStrengthRecordingAttachesToSeedHistorysWorkout() async throws {
        let env = try makeEnv(["-seedHistory"])
        _ = await env.health.enable()
        let workout = try #require(try env.workouts.recent(limit: 1).first) // 19 Sep, 18:00 UTC
        #expect(env.measuredActivity(for: workout)?.id == FakeHealthStore.uiTestStrengthId)
        #expect(!env.resolvedActivities().shown.map(\.id).contains(FakeHealthStore.uiTestStrengthId))
        #expect(env.countedActivityStarts().count == 1, "the walk counts; the attached recording doesn't")
    }

    @Test func theSwitchesHideWhatTheyRead() async throws {
        let env = try makeEnv()
        _ = await env.health.enable()
        env.setReadsOutsideWorkouts(false)
        #expect(env.resolvedActivities().shown.isEmpty)
        #expect(env.countedActivityStarts().isEmpty)
        env.setReadsActivityDays(false)
        #expect(env.recentActivityDays().isEmpty)
        #expect(try env.activities.activities(since: nil).count == 3, "nothing stored is deleted")
    }

    @Test func healthTurnedOnBeforePlan39WaitsForTheAsk() async throws {
        let env = try makeEnv(["-healthBeforeActivity"])
        #expect(env.health.isEnabled)
        #expect(env.health.showsActivityCard)
        await env.syncHealth()
        #expect(env.recentActivityDays().isEmpty, "nothing is read before the ask")
        await env.allowHealthActivity()
        #expect(!env.health.needsActivityPermission)
        #expect(env.recentActivityDays().count == 7)
    }

    @Test func aSignedOutLaunchMayImportActivity() throws {
        let env = try makeEnv() // held: the gate captures the environment weakly
        #expect(env.health.canImportActivity())
    }
}
