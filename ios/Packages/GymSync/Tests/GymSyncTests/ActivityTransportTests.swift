import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// Plan 39: the two activity tables on `/v1/sync` (server/src/sync/entities.ts, `health-activities` and
/// `activity-days`).
@Suite struct ActivityTransportTests {
    private let t0 = SyncDate.parse("2026-09-27T08:00:00.123456Z")!

    @Test func eachGoesUpAndComesDownOnItsOwnPath() async throws {
        let server = StubServer { request in
            request.method == "POST" ? .json(200, #"{"acks": []}"#) : .json(200, #"{"rows": []}"#)
        }
        let transport = ApiSyncTransport(api: server.client())
        let start = t0
        let walk = HealthActivity(id: UUID(), kind: "walking", startedAt: start, endedAt: start.addingTimeInterval(600),
                                  durationS: 600, sourceName: "Apple Watch")
        _ = try await transport.push(healthActivities: [HealthActivityDTO(SyncRow(value: walk, clientUpdatedAt: t0))])
        let day = ActivityDay(day: "2026-09-27", steps: 10, moveKcal: 1, exerciseMin: 0, standH: nil)
        _ = try await transport.push(activityDays: [ActivityDayDTO(SyncRow(value: day, clientUpdatedAt: t0))])
        _ = try await transport.pullHealthActivities(since: nil)
        _ = try await transport.pullActivityDays(since: nil)
        #expect(server.requests.map { "\($0.method) \($0.path)" } == [
            "POST /v1/sync/health-activities", "POST /v1/sync/activity-days",
            "GET /v1/sync/health-activities", "GET /v1/sync/activity-days",
        ])
    }

    @Test func daysPageByTheirDay() async throws {
        let page = #"{"rows": [{"day": "2026-09-27", "steps": 10, "move_kcal": 1, "exercise_min": 0, "stand_h": null, "#
            + #""client_updated_at": "2026-09-27T08:00:00.000000Z", "updated_at": "2026-11-08T10:00:00.100000Z"}]}"#
        let server = StubServer { request in
            let first = request.query["after"] == nil && request.query["since"] == nil
            return first ? .json(200, page) : .json(200, #"{"rows": []}"#)
        }
        let days = try await ApiSyncTransport(api: server.client(), pageSize: 1).pullActivityDays(since: nil)
        #expect(days.map(\.day) == ["2026-09-27"])
        #expect(server.requests.last?.query["after"] == "2026-09-27")
    }
}
