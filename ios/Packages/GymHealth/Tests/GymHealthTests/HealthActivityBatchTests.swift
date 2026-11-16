import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymHealth

/// Counts a context's saves (`ModelContext.didSave`, posted on the saving thread).
@MainActor
final class SaveCounter {
    private(set) var count = 0
    private nonisolated(unsafe) var observer: (any NSObjectProtocol)?

    init(_ context: ModelContext) {
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context,
                                                          queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }
}

/// Review finding M3: the activity import (on the main actor) stores a batch with one fetch per kind of lookup and one
/// save, where it used to fetch and save per workout and per day. These pin what it stores, which must not change.
@MainActor
@Suite struct HealthActivityBatchTests {
    private let day: TimeInterval = 86_400

    private func walk(_ fx: HealthFixture, daysAgo: Double, externalId: UUID? = nil) -> HealthOutsideWorkout {
        let start = fx.now.addingTimeInterval(-daysAgo * day)
        return HealthOutsideWorkout(activity: HealthActivity(
            id: UUID(), kind: "walking", startedAt: start, endedAt: start.addingTimeInterval(1_800), durationS: 1_800,
            kcal: 90, sourceName: "Strava"), externalId: externalId)
    }

    private func activityDay(_ fx: HealthFixture, daysAgo: Int, steps: Int) -> ActivityDay {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: fx.now)!
        return ActivityDay(day: ActivityDay.key(for: date, calendar: .current), steps: steps, moveKcal: 300,
                           exerciseMin: 30, standH: 10)
    }

    private func syncStore(_ fx: HealthFixture) -> SyncStore {
        SyncStore(context: fx.container.mainContext, defaults: fx.defaults)
    }

    @Test func aFirstImportStoresEveryWorkoutAndEveryDayInOneSaveEach() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore()
        let sync = fx.makeSync()
        _ = await sync.enable()
        let walks = (1...40).map { walk(fx, daysAgo: Double($0)) }
        for w in walks { await fx.store.addOutsideWorkout(w) }
        for offset in 0..<30 { await fx.store.setDay(activityDay(fx, daysAgo: offset, steps: 1_000 + offset)) }
        fx.advance()

        let saves = SaveCounter(fx.container.mainContext)
        await sync.importActivity()

        #expect(saves.count == 2, "one save for the workouts, one for the days")
        #expect(try fx.activities.activities(since: nil).count == 40)
        #expect(try syncStore(fx).dirtyHealthActivities().count == 40)
        #expect(try fx.activities.days(from: "2000-01-01", through: "2100-01-01").count == 30)
        #expect(fx.activityChanges == 1)
    }

    @Test func aRunWithNothingNewSavesNothing() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(outsideWorkouts: [walk(fx, daysAgo: 2)], days: [activityDay(fx, daysAgo: 1,
                                                                                             steps: 4_000)])
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let saves = SaveCounter(fx.container.mainContext)
        await sync.importActivity()
        #expect(saves.count == 0)
        #expect(fx.activityChanges == 1, "only the first run changed anything")
    }

    @Test func workoutsAlreadyHereLiveOrDeletedAreLeftAsTheyAre() async throws {
        let fx = try HealthFixture()
        let synced = walk(fx, daysAgo: 3), deleted = walk(fx, daysAgo: 4), new = walk(fx, daysAgo: 5)
        let store = syncStore(fx)
        try store.applyRemote(healthActivities: [
            SyncRow(value: synced.activity, clientUpdatedAt: fx.now, serverUpdatedAt: fx.now),
            SyncRow(value: deleted.activity, clientUpdatedAt: fx.now, deletedAt: fx.now, serverUpdatedAt: fx.now),
        ])
        fx.store = FakeHealthStore(outsideWorkouts: [synced, deleted, new, new])
        let sync = fx.makeSync()
        _ = await sync.enable()

        #expect(try fx.activities.activities(since: nil).map(\.id) == [synced.activity.id, new.activity.id])
        #expect(try fx.activities.activity(deleted.activity.id) == nil, "a tombstone never comes back")
        let dirty = try store.dirtyHealthActivities()
        #expect(dirty.map(\.value.id) == [new.activity.id], "the cloud's rows aren't touched")
        #expect(dirty.first?.clientUpdatedAt == new.activity.endedAt)
    }

    @Test func gymRollinsWorkoutsLiveRunningOrDeletedAreFoundInOneLookup() async throws {
        let fx = try HealthFixture()
        let live = try fx.finishWorkout(startOffset: -2 * day)
        let deleted = try fx.finishWorkout(startOffset: -3 * day)
        try fx.workouts.delete(deleted.id)
        let running = Workout(startedAt: fx.now, name: "Legs")
        try fx.workouts.saveActive(running, pausedAt: nil)
        let byLive = walk(fx, daysAgo: 2, externalId: live.id)
        let byDeleted = walk(fx, daysAgo: 3, externalId: deleted.id)
        let byRunning = walk(fx, daysAgo: 1, externalId: running.id)
        let foreign = walk(fx, daysAgo: 6, externalId: UUID())
        let plain = walk(fx, daysAgo: 7)
        fx.store = FakeHealthStore(outsideWorkouts: [byLive, byDeleted, byRunning, foreign, plain])
        _ = await fx.makeSync().enable()
        #expect(try fx.activities.activities(since: nil).map(\.id) == [foreign.activity.id, plain.activity.id])
    }

    @Test func deletionsTombstoneInOneSaveAndKeepTheUnmatchedInOrder() async throws {
        let fx = try HealthFixture()
        let a = walk(fx, daysAgo: 1), b = walk(fx, daysAgo: 2), c = walk(fx, daysAgo: 3)
        fx.store = FakeHealthStore(outsideWorkouts: [a, b, c])
        let sync = fx.makeSync()
        _ = await sync.enable()
        let store = syncStore(fx)
        for row in try store.dirtyHealthActivities() {
            try store.markSynced(.healthActivities, id: row.value.id.uuidString.lowercased(),
                                 clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: fx.now)
        }
        try fx.wipeLocalData()
        try store.applyRemote(healthActivities: [a, b].map {
            SyncRow(value: $0.activity, clientUpdatedAt: $0.activity.endedAt, serverUpdatedAt: fx.now)
        })
        for w in [a, c, b] { await fx.store.deleteOutsideWorkout(w.activity.id) }
        fx.advance()

        let saves = SaveCounter(fx.container.mainContext)
        await sync.importActivity()

        #expect(saves.count == 1)
        #expect(try fx.activities.activities(since: nil).isEmpty)
        #expect(Set(try store.dirtyHealthActivities().map(\.value.id)) == [a.activity.id, b.activity.id])
        #expect(try store.dirtyHealthActivities().allSatisfy { $0.deletedAt == fx.now })
        #expect(sync.state.unmatchedActivityDeletions == [c.activity.id], "c isn't here: it waits for the cloud")
    }

    @Test func daysAreWrittenOnlyWhenNewOrChangedInOneSave() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(days: (0..<5).map { activityDay(fx, daysAgo: $0, steps: 5_000 + $0) })
        let sync = fx.makeSync()
        _ = await sync.enable()
        let store = syncStore(fx)
        for row in try store.dirtyActivityDays() {
            try store.markSynced(.activityDays, id: row.value.day, clientUpdatedAt: row.clientUpdatedAt,
                                 serverUpdatedAt: fx.now)
        }
        await fx.store.setDay(activityDay(fx, daysAgo: 1, steps: 9_999))
        await fx.store.setDay(activityDay(fx, daysAgo: 3, steps: 7_777))
        fx.advance()

        let saves = SaveCounter(fx.container.mainContext)
        await sync.importActivity()

        #expect(saves.count == 1)
        let dirty = try store.dirtyActivityDays()
        #expect(dirty.map(\.value) == [activityDay(fx, daysAgo: 3, steps: 7_777),
                                       activityDay(fx, daysAgo: 1, steps: 9_999)])
        #expect(dirty.allSatisfy { $0.clientUpdatedAt == fx.now })
    }
}
