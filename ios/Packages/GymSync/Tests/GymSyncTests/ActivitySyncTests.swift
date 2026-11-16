import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymSync

/// Plan 39: outside workouts and days of activity on the wire and through a sync round.
@MainActor
@Suite struct ActivitySyncTests {
    let f: EngineFixture
    init() throws { f = try EngineFixture() }

    private var activities: ActivityRepository {
        ActivityRepository(context: f.container.mainContext, now: { [clock = f.clock] in clock.now })
    }

    private func walk(id: UUID = UUID(), kcal: Double? = 180) -> HealthActivity {
        let start = f.clock.now.addingTimeInterval(-86_400)
        return HealthActivity(id: id, kind: "walking", startedAt: start, endedAt: start.addingTimeInterval(2_700),
                              durationS: 2_700, kcal: kcal, distanceM: 3_400, avgHr: 102, maxHr: 121,
                              sourceName: "Apple Watch", fromWatch: true)
    }

    private let day = ActivityDay(day: "2026-09-25", steps: 8_532, moveKcal: 410, exerciseMin: 34, standH: nil)

    @Test func anOutsideWorkoutTravelsSnakeCasedWithExplicitNulls() throws {
        defer { f.tearDown() }
        let row = SyncRow(value: walk(kcal: nil), clientUpdatedAt: t0, deletedAt: t0)
        let body = String(decoding: try SyncJSON.encoder.encode(HealthActivityDTO(row)), as: UTF8.self)
        for key in [#""kcal":null"#, #""source_name":"Apple Watch""#, #""from_watch":true"#, #""duration_s":2700"#,
                    #""deleted_at":"#] {
            #expect(body.contains(key), "\(key) in \(body)")
        }
        #expect(!body.contains(#""updated_at""#), "updated_at is the server's")
        let back = try wire(HealthActivityDTO(row)).toDomain()
        #expect(back.value == row.value)
        #expect(back.deletedAt == t0)
    }

    @Test func aDayTravelsWithItsKeyAndANullStand() throws {
        defer { f.tearDown() }
        let row = SyncRow(value: day, clientUpdatedAt: t0)
        let body = String(decoding: try SyncJSON.encoder.encode(ActivityDayDTO(row)), as: UTF8.self)
        #expect(body.contains(#""day":"2026-09-25""#) && body.contains(#""stand_h":null"#))
        #expect(try wire(ActivityDayDTO(row)).toDomain().value == day)
    }

    @Test func importedActivityIsPushedAndMarkedSynced() async throws {
        defer { f.tearDown() }
        let walk = walk()
        try activities.add(walk, editedAt: walk.endedAt)
        try activities.save(day: day)

        await f.engine.sync()

        #expect(await f.server.healthActivities[walk.id]?.kind == "walking")
        #expect(await f.server.activityDays[day.day]?.steps == 8_532)
        #expect(try f.store.dirtyHealthActivities().isEmpty)
        #expect(try f.store.dirtyActivityDays().isEmpty)
    }

    @Test func anotherDevicesRowsArePulledTombstonesIncluded() async throws {
        defer { f.tearDown() }
        let live = walk(), gone = walk()
        try await f.server.seed(healthActivity: HealthActivityDTO(SyncRow(value: live, clientUpdatedAt: f.clock.now)))
        try await f.server.seed(healthActivity: HealthActivityDTO(SyncRow(value: gone, clientUpdatedAt: f.clock.now,
                                                                          deletedAt: f.clock.now)))
        try await f.server.seed(activityDay: ActivityDayDTO(SyncRow(value: day, clientUpdatedAt: f.clock.now)))

        await f.engine.sync()

        #expect(try activities.activity(live.id) == live)
        #expect(try activities.activity(gone.id) == nil)
        #expect(try activities.hasRecord(id: gone.id))
        #expect(try activities.days(from: day.day, through: day.day) == [day])
        #expect(f.store.cursor(for: .healthActivities) != nil)
        #expect(f.store.cursor(for: .activityDays) != nil)
    }

    @Test func aRowTheServerRefusesIsRecordedAndTheRestSync() async throws {
        defer { f.tearDown() }
        let refused = walk(), fine = walk()
        try activities.add(refused, editedAt: refused.endedAt)
        try activities.add(fine, editedAt: fine.endedAt)
        await f.server.reject(ids: [refused.id.uuidString])

        await f.engine.sync()

        #expect(await f.server.healthActivities[fine.id] != nil)
        #expect(await f.server.healthActivities[refused.id] == nil)
        #expect(f.store.syncFailures().map(\.entity) == [.healthActivities])
    }
}
