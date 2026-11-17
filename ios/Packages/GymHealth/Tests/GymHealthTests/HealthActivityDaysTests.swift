import Foundation
import GymCore
import GymData
import Testing
@testable import GymHealth

/// Plan 39: days of activity (two years the first time, then from 6 days before the last read, written only when a
/// value changed), and asking for the activity types when Health was turned on before plan 39.
@MainActor
@Suite struct HealthActivityDaysTests {
    private let calendar = Calendar.current

    private func key(_ fx: HealthFixture, daysAgo: Int) -> String {
        ActivityDay.key(for: calendar.date(byAdding: .day, value: -daysAgo, to: fx.now)!, calendar: calendar)
    }

    private func day(_ fx: HealthFixture, daysAgo: Int, steps: Int) -> ActivityDay {
        ActivityDay(day: key(fx, daysAgo: daysAgo), steps: steps, moveKcal: 300, exerciseMin: 30, standH: 10)
    }

    @Test func theFirstReadCoversTwoYearsAndLaterOnesTheLastWeek() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(days: [day(fx, daysAgo: 1, steps: 8_000)])
        let sync = fx.makeSync()
        _ = await sync.enable()
        let first = try #require(await fx.store.dayReads.first)
        #expect(first.from == calendar.startOfDay(for: fx.now.addingTimeInterval(-HealthSync.importWindow)))
        #expect(first.through == calendar.startOfDay(for: fx.now))

        let enabledAt = fx.now
        fx.advance(86_400)
        await sync.importActivity()
        let next = try #require(await fx.store.dayReads.last)
        #expect(next.from == calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: enabledAt)))
        #expect(next.through == calendar.startOfDay(for: fx.now))
    }

    @Test func anEmptyFirstReadIsNotRememberedSoTheNextOneStartsTwoYearsBack() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore()
        let sync = fx.makeSync()
        _ = await sync.enable()
        #expect(sync.state.activityDaysReadAt == nil, "a denied read looks like an empty one")
        fx.advance(86_400)
        await sync.importActivity()
        let reads = await fx.store.dayReads
        let earliest = calendar.startOfDay(for: fx.now.addingTimeInterval(-HealthSync.importWindow))
        #expect(reads.count == 2)
        #expect(reads.last?.from == earliest)
    }

    @Test func onlyNewOrChangedDaysAreWrittenAgain() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(days: [day(fx, daysAgo: 1, steps: 8_000), day(fx, daysAgo: 20, steps: 5_000)])
        let sync = fx.makeSync()
        _ = await sync.enable()
        let store = SyncStore(context: fx.container.mainContext, defaults: fx.defaults)
        for row in try store.dirtyActivityDays() {
            try store.markSynced(.activityDays, id: row.value.day, clientUpdatedAt: row.clientUpdatedAt,
                                 serverUpdatedAt: fx.now)
        }

        await fx.store.setDay(day(fx, daysAgo: 1, steps: 9_000))   // late Apple Watch data
        await fx.store.setDay(day(fx, daysAgo: 20, steps: 6_000))  // too old for the weekly re-read
        await fx.store.setDay(day(fx, daysAgo: 0, steps: 1_200))   // today's first data
        fx.advance(3_600)
        await sync.importActivity()

        #expect(try store.dirtyActivityDays().map(\.value.day) == [key(fx, daysAgo: 1), key(fx, daysAgo: 0)])
        let old = try fx.activities.days(from: key(fx, daysAgo: 20), through: key(fx, daysAgo: 20))
        #expect(old.map(\.steps) == [5_000])
    }

    @Test func aDayOutsideTheLimitsIsSkipped() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(days: [day(fx, daysAgo: 1, steps: 250_000), day(fx, daysAgo: 2, steps: 4_000)])
        _ = await fx.makeSync().enable()
        #expect(try fx.activities.days(from: "2000-01-01", through: "2100-01-01").map(\.steps) == [4_000])
    }

    @Test func turningStepsOffStopsTheReadAndKeepsWhatIsStored() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(days: [day(fx, daysAgo: 1, steps: 4_000)])
        let sync = fx.makeSync()
        _ = await sync.enable()
        sync.setReadsActivityDays(false)
        let reads = await fx.store.dayReads.count
        await sync.importActivity()
        #expect(await fx.store.dayReads.count == reads)
        #expect(try fx.activities.days(from: "2000-01-01", through: "2100-01-01").count == 1)
    }

    @Test func enablingAsksForTheActivityTypesOnce() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        #expect(await fx.store.authorizationRequests == 1)
        #expect(sync.state.activityPermissionsAsked)
        #expect(!sync.needsActivityPermission && !sync.showsActivityCard)
    }

    @Test func healthTurnedOnBeforePlan39ReadsNoActivityUntilAllowed() async throws {
        let fx = try HealthFixture()
        try HealthSyncState.saveEnabledBeforeActivity(to: fx.defaults, at: fx.now)
        fx.store = FakeHealthStore(days: [day(fx, daysAgo: 1, steps: 4_000)])
        let sync = fx.makeSync()
        await sync.sync()
        #expect(sync.isEnabled)
        #expect(await fx.store.dayReads.isEmpty)
        #expect(sync.needsActivityPermission && sync.showsActivityCard)

        sync.dismissActivityCard()
        #expect(!sync.showsActivityCard && sync.needsActivityPermission, "Settings still asks")

        #expect(await sync.allowActivity())
        #expect(await fx.store.authorizationRequests == 1)
        #expect(!sync.needsActivityPermission)
        #expect(try fx.activities.days(from: "2000-01-01", through: "2100-01-01").count == 1)
    }
}
