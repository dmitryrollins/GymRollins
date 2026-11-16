import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

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

/// Review finding M3: the Health import's batch calls. One fetch per lookup and one save per batch, with what each
/// stores exactly what the one-at-a-time calls store.
@MainActor
@Suite struct ActivityRepositoryBatchTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    private var clock: TestClock { f.clock }
    private var context: ModelContext { f.context }
    private var store: SyncStore { f.store }
    private var workouts: WorkoutRepository { f.workouts }
    private var repo: ActivityRepository {
        ActivityRepository(context: f.context, now: { [clock = f.clock] in clock.now })
    }

    private func walk(daysAgo: Double, kcal: Double? = 180) -> HealthActivity {
        let start = clock.now.addingTimeInterval(-daysAgo * 86_400)
        return HealthActivity(id: UUID(), kind: "walking", startedAt: start, endedAt: start.addingTimeInterval(2_700),
                              durationS: 2_700, kcal: kcal, sourceName: "Apple Watch", fromWatch: true)
    }

    private func day(_ key: String, steps: Int) -> ActivityDay {
        ActivityDay(day: key, steps: steps, moveKcal: 300, exerciseMin: 30, standH: nil)
    }

    // MARK: Outside workouts

    @Test func aBatchStoresTheNewOnesInOneSaveAndSkipsWhatIsHere() throws {
        defer { f.tearDown() }
        let live = walk(daysAgo: 1), gone = walk(daysAgo: 2), first = walk(daysAgo: 3), second = walk(daysAgo: 4)
        try repo.add(live, editedAt: live.endedAt)
        try repo.add(gone, editedAt: gone.endedAt)
        try repo.delete(gone.id)
        clock.advance()

        let saves = SaveCounter(context)
        let added = try repo.add([live, gone, first, second, first], editedAt: { $0.endedAt })

        #expect(added == [first.id, second.id], "one already here, one a tombstone, one a repeat")
        #expect(saves.count == 1)
        #expect(try repo.activities(since: nil) == [live, first, second])
        #expect(try repo.activity(gone.id) == nil)
        let dirty = try store.dirtyHealthActivities().filter { [first.id, second.id].contains($0.value.id) }
        #expect(dirty.count == 2)
        #expect(dirty.allSatisfy { $0.clientUpdatedAt == $0.value.endedAt })
    }

    @Test func aBatchWithNothingNewDoesntSave() throws {
        defer { f.tearDown() }
        let live = walk(daysAgo: 1)
        try repo.add(live, editedAt: live.endedAt)
        let saves = SaveCounter(context)
        #expect(try repo.add([live], editedAt: { $0.endedAt }).isEmpty)
        #expect(try repo.add([], editedAt: { $0.endedAt }).isEmpty)
        #expect(saves.count == 0)
    }

    @Test func aBatchWithOneOutsideTheLimitsStoresNone() throws {
        defer { f.tearDown() }
        let fine = walk(daysAgo: 1), burning = walk(daysAgo: 2, kcal: 20_001)
        #expect(throws: GymDataError.self) { try repo.add([fine, burning], editedAt: { $0.endedAt }) }
        #expect(try repo.activities(since: nil).isEmpty)
    }

    @Test func aLargeBatchIsStoredWhole() throws {
        defer { f.tearDown() }
        let many = (0..<1_234).map { walk(daysAgo: Double($0) / 4) }
        try repo.add(Array(many.prefix(600)), editedAt: { $0.endedAt })
        let saves = SaveCounter(context)
        #expect(try repo.add(many, editedAt: { $0.endedAt }).count == 634)
        #expect(saves.count == 1)
        #expect(try repo.activities(since: nil).count == 1_234)
    }

    @Test func aBatchOfDeletionsTombstonesTheLiveOnesInOneSave() throws {
        defer { f.tearDown() }
        let a = walk(daysAgo: 1), b = walk(daysAgo: 2), gone = walk(daysAgo: 3)
        for activity in [a, b, gone] { try repo.add(activity, editedAt: activity.endedAt) }
        try repo.delete(gone.id)
        clock.advance()
        let unknown = UUID(), other = UUID()

        let saves = SaveCounter(context)
        let result = try repo.delete([unknown, a.id, gone.id, b.id, a.id, other, unknown])

        #expect(result.deleted == [a.id, b.id])
        #expect(result.missing == [unknown, other, unknown], "in order, repeats kept, as one call each would")
        #expect(saves.count == 1)
        #expect(try repo.activities(since: nil).isEmpty)
        let rows = try store.dirtyHealthActivities().filter { [a.id, b.id].contains($0.value.id) }
        #expect(rows.count == 2 && rows.allSatisfy { $0.deletedAt == clock.now && $0.clientUpdatedAt == clock.now })
    }

    @Test func deletionsWithNothingLiveDontSave() throws {
        defer { f.tearDown() }
        let saves = SaveCounter(context)
        let result = try repo.delete([UUID()])
        #expect(result.deleted.isEmpty && result.missing.count == 1)
        let none = try repo.delete([])
        #expect(none.deleted.isEmpty && none.missing.isEmpty)
        #expect(saves.count == 0)
    }

    // MARK: Days

    @Test func aBatchOfDaysWritesOnlyNewOrChangedOnesInOneSave() throws {
        defer { f.tearDown() }
        try repo.save(day: day("2026-09-20", steps: 1_000))
        try repo.save(day: day("2026-09-21", steps: 2_000))
        try store.markSynced(.activityDays, id: "2026-09-20", clientUpdatedAt: clock.now, serverUpdatedAt: clock.now)
        try store.markSynced(.activityDays, id: "2026-09-21", clientUpdatedAt: clock.now, serverUpdatedAt: clock.now)
        clock.advance()

        let saves = SaveCounter(context)
        let written = try repo.save(days: [day("2026-09-20", steps: 1_000), day("2026-09-21", steps: 2_500),
                                           day("2026-09-22", steps: 3_000), day("2026-09-22", steps: 3_100)])

        #expect(written == ["2026-09-21", "2026-09-22", "2026-09-22"], "as one call per day would answer")
        #expect(saves.count == 1)
        #expect(try repo.days(from: "2026-09-20", through: "2026-09-22")
            == [day("2026-09-20", steps: 1_000), day("2026-09-21", steps: 2_500), day("2026-09-22", steps: 3_100)])
        let dirty = try store.dirtyActivityDays()
        #expect(dirty.map(\.value.day) == ["2026-09-21", "2026-09-22"])
        #expect(dirty.first?.clientUpdatedAt == clock.now)
    }

    @Test func aBatchOfUnchangedDaysDoesntSave() throws {
        defer { f.tearDown() }
        try repo.save(day: day("2026-09-20", steps: 1_000))
        let saves = SaveCounter(context)
        #expect(try repo.save(days: [day("2026-09-20", steps: 1_000)]).isEmpty)
        #expect(try repo.save(days: []).isEmpty)
        #expect(saves.count == 0)
    }

    @Test func aBatchOfDaysWithOneOutsideTheLimitsWritesNone() throws {
        defer { f.tearDown() }
        #expect(throws: GymDataError.self) {
            try repo.save(days: [day("2026-09-20", steps: 1_000), day("2026-09-21", steps: 200_001)])
        }
        #expect(try repo.days(from: "2000-01-01", through: "2100-01-01").isEmpty)
    }

    // MARK: GymRollins workouts

    @Test func theWorkoutIdsHereAreFoundLiveRunningOrDeleted() throws {
        defer { f.tearDown() }
        let start = clock.now.addingTimeInterval(-86_400)
        let live = Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: "Push")
        let deleted = Workout(startedAt: start.addingTimeInterval(-86_400),
                              endedAt: start.addingTimeInterval(-82_800), name: "Pull")
        let running = Workout(startedAt: clock.now, name: "Legs")
        try workouts.save(live)
        try workouts.save(deleted)
        try workouts.delete(deleted.id)
        try workouts.saveActive(running, pausedAt: nil)
        let unknown = UUID()
        #expect(try workouts.recordedIds(among: [live.id, deleted.id, running.id, unknown])
            == [live.id, deleted.id, running.id])
        #expect(try workouts.recordedIds(among: []).isEmpty)
    }
}
