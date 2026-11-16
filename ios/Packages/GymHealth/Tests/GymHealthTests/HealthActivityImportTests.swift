import Foundation
import GymCore
import GymData
import Testing
@testable import GymHealth

/// Plan 39: outside workouts from Apple Health. Every workout GymRollins didn't write comes in (two years back the
/// first time), deletions in Health tombstone the row, and the switch and the cloud gate stop the import.
@MainActor
@Suite struct HealthActivityImportTests {
    private let day: TimeInterval = 86_400

    private func outside(_ fx: HealthFixture, daysAgo: Double, kind: String = "walking", externalId: UUID? = nil,
                         ours: Bool = false) -> HealthOutsideWorkout {
        let start = fx.now.addingTimeInterval(-daysAgo * day)
        return HealthOutsideWorkout(activity: HealthActivity(
            id: UUID(), kind: kind, startedAt: start, endedAt: start.addingTimeInterval(2_700), durationS: 2_700,
            kcal: 180, sourceName: "Apple Watch", fromWatch: true), externalId: externalId, writtenByGymRollins: ours)
    }

    @Test func enablingImportsTwoYearsOfOtherAppsWorkouts() async throws {
        let fx = try HealthFixture()
        let recent = outside(fx, daysAgo: 3), old = outside(fx, daysAgo: 800)
        fx.store = FakeHealthStore(outsideWorkouts: [recent, old])
        let sync = fx.makeSync()
        _ = await sync.enable()
        #expect(try fx.activities.activities(since: nil) == [recent.activity])
        #expect(fx.activityChanges == 1)
        #expect(sync.state.activityAnchor != nil)
        let rows = try SyncStore(context: fx.container.mainContext, defaults: fx.defaults).dirtyHealthActivities()
        #expect(rows.first?.clientUpdatedAt == recent.activity.endedAt, "the workout's own end is its edit time")
    }

    @Test func anEmptyFirstReadKeepsTheAnchorUnsetSoLaterAccessImportsTheHistory() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore()
        let sync = fx.makeSync()
        _ = await sync.enable()
        #expect(sync.state.activityAnchor == nil, "a denied read looks like an empty one")
        #expect(sync.state.activityImportStart == nil)
        let walk = outside(fx, daysAgo: 365)
        await fx.store.addOutsideWorkout(walk)
        fx.advance()
        await sync.importActivity()
        #expect(try fx.activities.activities(since: nil) == [walk.activity])
        #expect(sync.state.activityAnchor != nil)
    }

    @Test func anotherAccountForgetsTheImportProgressSoItGetsTheHistoryToo() async throws {
        let fx = try HealthFixture()
        let walk = outside(fx, daysAgo: 3)
        fx.store = FakeHealthStore(outsideWorkouts: [walk], days: [ActivityDay(
            day: ActivityDay.key(for: fx.now.addingTimeInterval(-day), calendar: .current), steps: 5_000,
            moveKcal: 300, exerciseMin: 30, standH: 10)])
        let sync = fx.makeSync()
        var owner = "A"
        sync.owner = { owner }
        _ = await sync.enable()
        #expect(sync.state.activityAnchor != nil && sync.state.activityDaysReadAt != nil)
        sync.localDataWasReset()
        try fx.wipeLocalData()
        owner = "B"
        sync.localDataRestored(lastPull: fx.now.addingTimeInterval(1))
        #expect(sync.state.activityAnchor == nil && sync.state.activityImportStart == nil)
        #expect(sync.state.activityDaysReadAt == nil && sync.state.unmatchedActivityDeletions.isEmpty)
        fx.advance()
        await sync.importActivity()
        #expect(try fx.activities.activities(since: nil) == [walk.activity])
    }

    @Test func theSameAccountKeepsTheImportProgress() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(outsideWorkouts: [outside(fx, daysAgo: 3)], days: [ActivityDay(
            day: ActivityDay.key(for: fx.now.addingTimeInterval(-day), calendar: .current), steps: 5_000,
            moveKcal: 300, exerciseMin: 30, standH: 10)])
        let sync = fx.makeSync()
        sync.owner = { "A" }
        _ = await sync.enable()
        sync.localDataWasReset()
        try fx.wipeLocalData()
        sync.localDataRestored(lastPull: fx.now.addingTimeInterval(1))
        #expect(sync.state.activityAnchor != nil && sync.state.activityImportStart != nil)
        #expect(sync.state.activityDaysReadAt != nil)
    }

    @Test func gymRollinsOwnWorkoutsNeverComeIn() async throws {
        let fx = try HealthFixture()
        let exported = try fx.finishWorkout(startOffset: -2 * day)
        let deleted = try fx.finishWorkout(startOffset: -4 * day)
        try fx.workouts.delete(deleted.id)
        let marked = outside(fx, daysAgo: 1, kind: "traditional_strength", ours: true)
        let byId = outside(fx, daysAgo: 2, kind: "traditional_strength", externalId: exported.id)
        let byDeletedId = outside(fx, daysAgo: 4, kind: "traditional_strength", externalId: deleted.id)
        let otherApps = outside(fx, daysAgo: 5, externalId: UUID()) // another app's own external id
        fx.store = FakeHealthStore(outsideWorkouts: [marked, byId, byDeletedId, otherApps])
        _ = await fx.makeSync().enable()
        #expect(try fx.activities.activities(since: nil).map(\.id) == [otherApps.activity.id])
    }

    @Test func aRideComesInWithItsPowerCadenceAndTotalCalories() async throws {
        let fx = try HealthFixture()
        let start = fx.now.addingTimeInterval(-day)
        let ride = HealthActivity(id: UUID(), kind: "cycling", startedAt: start, endedAt: start.addingTimeInterval(810),
                                  durationS: 810, kcal: 40, totalKcal: 48, avgHr: 118, maxHr: 141, avgPowerW: 138,
                                  avgCadenceRpm: 62, sourceName: "Apple Watch", fromWatch: true)
        fx.store = FakeHealthStore(outsideWorkouts: [HealthOutsideWorkout(activity: ride)])
        _ = await fx.makeSync().enable()
        #expect(try fx.activities.activities(since: nil) == [ride])
        let rows = try SyncStore(context: fx.container.mainContext, defaults: fx.defaults).dirtyHealthActivities()
        #expect(rows.map(\.value) == [ride], "pushed with them too")
    }

    /// Review finding L2: an optional value outside its limit is dropped and the workout kept; only a required field
    /// outside its limit skips the workout.
    @Test func anOptionalValueOutsideItsLimitIsDroppedAndTheWorkoutKept() async throws {
        let fx = try HealthFixture()
        let start = fx.now.addingTimeInterval(-day)
        let odd = HealthActivity(id: UUID(), kind: "walking", startedAt: start, endedAt: start.addingTimeInterval(600),
                                 durationS: 600, kcal: 60, totalKcal: 25_000, distanceM: 800, avgHr: 300, maxHr: 140,
                                 avgPowerW: 3_000, avgCadenceRpm: 90, sourceName: "Old App")
        let tooLong = HealthActivity(id: UUID(), kind: "walking", startedAt: start,
                                     endedAt: start.addingTimeInterval(600), durationS: 90_000, sourceName: "Old App")
        let nameless = HealthActivity(id: UUID(), kind: "walking", startedAt: start,
                                      endedAt: start.addingTimeInterval(600), durationS: 600, avgHr: 300,
                                      sourceName: "")
        let fine = outside(fx, daysAgo: 2)
        fx.store = FakeHealthStore(outsideWorkouts: [odd, tooLong, nameless].map { HealthOutsideWorkout(activity: $0) }
            + [fine])
        _ = await fx.makeSync().enable()
        #expect(try fx.activities.activities(since: nil).map(\.id) == [odd.id, fine.activity.id])
        #expect(try fx.activities.activity(odd.id)
            == HealthActivity(id: odd.id, kind: "walking", startedAt: start, endedAt: start.addingTimeInterval(600),
                              durationS: 600, kcal: 60, distanceM: 800, maxHr: 140, avgCadenceRpm: 90,
                              sourceName: "Old App"))
        #expect(try !fx.activities.hasRecord(id: tooLong.id), "a required field outside its limit skips it")
        #expect(try !fx.activities.hasRecord(id: nameless.id))
    }

    @Test func aDeletionInHealthLeavesATombstoneThatSyncs() async throws {
        let fx = try HealthFixture()
        let walk = outside(fx, daysAgo: 1)
        fx.store = FakeHealthStore(outsideWorkouts: [walk])
        let sync = fx.makeSync()
        _ = await sync.enable()
        await fx.store.deleteOutsideWorkout(walk.activity.id)
        fx.advance()
        await sync.importActivity()
        #expect(try fx.activities.activity(walk.activity.id) == nil)
        #expect(try fx.activities.hasRecord(id: walk.activity.id))
        let rows = try SyncStore(context: fx.container.mainContext, defaults: fx.defaults).dirtyHealthActivities()
        #expect(rows.first?.deletedAt == fx.now)
        #expect(fx.activityChanges == 2)
    }

    @Test func aDeletionForARowNotHereYetWaitsForItToComeFromTheCloud() async throws {
        let fx = try HealthFixture()
        let walk = outside(fx, daysAgo: 1)
        fx.store = FakeHealthStore(outsideWorkouts: [walk])
        let sync = fx.makeSync()
        _ = await sync.enable()
        try fx.wipeLocalData() // signed out: the row is gone from this iPhone, not deleted
        await fx.store.deleteOutsideWorkout(walk.activity.id)
        await sync.importActivity()
        #expect(sync.state.unmatchedActivityDeletions == [walk.activity.id])

        let store = SyncStore(context: fx.container.mainContext, defaults: fx.defaults)
        try store.applyRemote(healthActivities: [SyncRow(value: walk.activity, clientUpdatedAt: walk.activity.endedAt,
                                                         serverUpdatedAt: fx.now)])
        fx.advance()
        await sync.importActivity()
        #expect(try fx.activities.activity(walk.activity.id) == nil, "deleted once it came back")
        #expect(sync.state.unmatchedActivityDeletions.isEmpty)
    }

    @Test func turningWorkoutsFromOtherAppsOffStopsTheImportAndOnResumesIt() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        sync.setReadsOutsideWorkouts(false)
        let walk = outside(fx, daysAgo: 1)
        await fx.store.addOutsideWorkout(walk)
        await sync.importActivity()
        #expect(try fx.activities.activities(since: nil).isEmpty)

        sync.setReadsOutsideWorkouts(true)
        await sync.importActivity()
        #expect(try fx.activities.activities(since: nil) == [walk.activity])
    }

    @Test func nothingIsReadWhileTheFirstCloudPullIsPending() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(outsideWorkouts: [outside(fx, daysAgo: 1)])
        let sync = fx.makeSync()
        var pulled = false
        sync.canImportActivity = { pulled }
        _ = await sync.enable()
        #expect(try fx.activities.activities(since: nil).isEmpty)
        #expect(sync.state.activityAnchor == nil)
        pulled = true
        await sync.importActivity()
        #expect(try fx.activities.activities(since: nil).count == 1)
    }

    @Test func aResetDuringTheReadWritesNothing() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        await fx.store.addOutsideWorkout(outside(fx, daysAgo: 1))
        await fx.store.setGate(true)
        let run = Task { await sync.importActivity() }
        while await fx.store.parkedCount == 0 { await Task.yield() }
        sync.reset()
        await fx.store.setGate(false)
        await run.value
        #expect(try fx.activities.activities(since: nil).isEmpty)
        #expect(sync.state.activityAnchor == nil)
    }

    @Test func aFailedReadSaysSoAndTheNextOneRecovers() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        await fx.store.addOutsideWorkout(outside(fx, daysAgo: 1))
        await fx.store.setFailReads(true)
        await sync.importActivity()
        #expect(sync.lastError == "Couldn't read your activity from Apple Health. We'll try again next time.")
        await fx.store.setFailReads(false)
        await sync.importActivity()
        #expect(try fx.activities.activities(since: nil).count == 1)
    }
}
