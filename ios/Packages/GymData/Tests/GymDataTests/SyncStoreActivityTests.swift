import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Plan 39: outside workouts and days of activity as sync kinds: dirty after an import, clean after the ack, pulled by
/// last write wins, wiped with the account, and moved to another server.
@MainActor
@Suite struct SyncStoreActivityTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    private var activities: ActivityRepository {
        ActivityRepository(context: f.context, now: { [clock = f.clock] in clock.now })
    }

    private func walk(id: UUID = UUID()) -> HealthActivity {
        let start = f.clock.now.addingTimeInterval(-86_400)
        return HealthActivity(id: id, kind: "walking", startedAt: start, endedAt: start.addingTimeInterval(2_700),
                              durationS: 2_700, sourceName: "Apple Watch", fromWatch: true)
    }

    private let day = ActivityDay(day: "2026-09-21", steps: 8_532, moveKcal: 410, exerciseMin: 34, standH: 11)

    @Test func importedRowsAreDirtyUntilTheServerTakesThem() throws {
        defer { f.tearDown() }
        let walk = walk()
        try activities.add(walk, editedAt: walk.endedAt)
        try activities.save(day: day)
        let rows = try f.store.dirtyHealthActivities()
        #expect(rows.map(\.value) == [walk])
        #expect(rows.first?.clientUpdatedAt == walk.endedAt)
        #expect(try f.store.dirtyActivityDays().map(\.value) == [day])

        try f.store.markSynced(.healthActivities, id: walk.id.uuidString.lowercased(),
                               clientUpdatedAt: walk.endedAt, serverUpdatedAt: f.clock.now)
        try f.store.markSynced(.activityDays, id: day.day, clientUpdatedAt: f.clock.now, serverUpdatedAt: f.clock.now)
        #expect(try f.store.dirtyHealthActivities().isEmpty)
        #expect(try f.store.dirtyActivityDays().isEmpty)
    }

    @Test func aPulledTombstoneIsKeptSoTheImportCantBringTheWorkoutBack() throws {
        defer { f.tearDown() }
        let walk = walk()
        try f.store.applyRemote(healthActivities: [SyncRow(value: walk, clientUpdatedAt: f.clock.now,
                                                           deletedAt: f.clock.now, serverUpdatedAt: f.clock.now)])
        #expect(try activities.activity(walk.id) == nil)
        #expect(try activities.hasRecord(id: walk.id))
        #expect(try !activities.add(walk, editedAt: walk.endedAt))
        #expect(try f.store.dirtyHealthActivities().isEmpty)
    }

    @Test func aRidesPowerCadenceAndTotalCaloriesArePushedAndPulled() throws {
        defer { f.tearDown() }
        let start = f.clock.now.addingTimeInterval(-3_600)
        let ride = HealthActivity(id: UUID(), kind: "cycling", startedAt: start, endedAt: start.addingTimeInterval(810),
                                  durationS: 810, kcal: 40, totalKcal: 48, avgHr: 118, maxHr: 141, avgPowerW: 138,
                                  avgCadenceRpm: 62, sourceName: "Apple Watch", fromWatch: true)
        try activities.add(ride, editedAt: ride.endedAt)
        #expect(try f.store.dirtyHealthActivities().map(\.value) == [ride])
        #expect(try activities.activity(ride.id) == ride)

        let remeasured = HealthActivity(id: ride.id, kind: "cycling", startedAt: start,
                                        endedAt: start.addingTimeInterval(810), durationS: 810, kcal: 41,
                                        totalKcal: 50, avgPowerW: 140, avgCadenceRpm: 64, sourceName: "Apple Watch",
                                        fromWatch: true)
        try f.store.applyRemote(healthActivities: [SyncRow(value: remeasured,
                                                           clientUpdatedAt: f.clock.now.addingTimeInterval(60),
                                                           serverUpdatedAt: f.clock.now)])
        #expect(try activities.activity(ride.id) == remeasured)
        let other = HealthActivity(id: UUID(), kind: "cycling", startedAt: start, endedAt: start.addingTimeInterval(60),
                                   durationS: 60, totalKcal: 9, avgPowerW: 101, sourceName: "Zwift")
        try f.store.applyRemote(healthActivities: [SyncRow(value: other, clientUpdatedAt: f.clock.now,
                                                           serverUpdatedAt: f.clock.now)])
        #expect(try activities.activity(other.id) == other, "a pulled row that's new here keeps them too")
    }

    @Test func aNewerPulledRowWinsAndAnOlderOneDoesNot() throws {
        defer { f.tearDown() }
        try activities.save(day: day)
        let older = ActivityDay(day: day.day, steps: 1, moveKcal: 1, exerciseMin: 1, standH: nil)
        try f.store.applyRemote(activityDays: [SyncRow(value: older,
                                                       clientUpdatedAt: f.clock.now.addingTimeInterval(-60))])
        #expect(try activities.days(from: day.day, through: day.day) == [day])
        let newer = ActivityDay(day: day.day, steps: 9_000, moveKcal: 450, exerciseMin: 40, standH: 12)
        try f.store.applyRemote(activityDays: [SyncRow(value: newer,
                                                       clientUpdatedAt: f.clock.now.addingTimeInterval(60),
                                                       serverUpdatedAt: f.clock.now)])
        #expect(try activities.days(from: day.day, through: day.day) == [newer])
        #expect(try f.store.dirtyActivityDays().isEmpty)
    }

    @Test func theyAreAccountDataWipedOnSignOutAndMovedToAnotherServer() throws {
        defer { f.tearDown() }
        try activities.save(day: day)
        #expect(try f.store.hasLocalData())
        try f.store.markSynced(.activityDays, id: day.day, clientUpdatedAt: f.clock.now, serverUpdatedAt: f.clock.now)
        f.store.syncedServer = "https://old.example"
        #expect(try f.store.moveToServer("https://new.example"))
        #expect(try f.store.dirtyActivityDays().map(\.value) == [day])

        try f.store.resetAccountData()
        #expect(try activities.days(from: "2000-01-01", through: "2100-01-01").isEmpty)
        #expect(try !f.store.hasLocalData())
    }
}
