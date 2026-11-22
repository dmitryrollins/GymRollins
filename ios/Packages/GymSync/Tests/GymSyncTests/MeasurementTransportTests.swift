import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// Plan 40: the measured numbers on `/v1/sync/workout-measurements` (server/src/sync/entities.ts), paged by workout id.
@Suite struct MeasurementTransportTests {
    private let t0 = SyncDate.parse("2026-09-19T19:00:00.123456Z")!

    @Test func theyGoUpAndComeDownOnTheirOwnPath() async throws {
        let server = StubServer { request in
            request.method == "POST" ? .json(200, #"{"acks": []}"#) : .json(200, #"{"rows": []}"#)
        }
        let transport = ApiSyncTransport(api: server.client())
        let numbers = MeasurementSnapshot(workoutId: UUID(), recordedBy: .watch, durationS: 3_500, activeKcal: 412,
                                          totalKcal: 489, avgHr: 128, maxHr: 162, postHr: 124, effort: 6,
                                          effortEstimated: false, clientUpdatedAt: t0)
        _ = try await transport.push(workoutMeasurements: [WorkoutMeasurementDTO(SyncRow(value: numbers,
                                                                                        clientUpdatedAt: t0))])
        _ = try await transport.pullWorkoutMeasurements(since: nil)
        #expect(server.requests.map { "\($0.method) \($0.path)" } == [
            "POST /v1/sync/workout-measurements", "GET /v1/sync/workout-measurements",
        ])
    }

    @Test func theyPageByTheirWorkoutId() async throws {
        let id = "8a1f3c52-6d0e-4b7a-9c21-5e4d3b2a1f00"
        let page = #"{"rows": [{"workout_id": "\#(id)", "recorded_by": "watch", "duration_s": 3500, "#
            + #""active_kcal": 412, "total_kcal": 489, "avg_hr": 128, "max_hr": 162, "post_hr": 124, "effort": 6, "#
            + #""effort_estimated": false, "client_updated_at": "2026-09-19T19:00:00.000000Z", "deleted_at": null, "#
            + #""updated_at": "2026-11-16T10:00:00.100000Z"}]}"#
        let server = StubServer { request in
            let first = request.query["after"] == nil && request.query["since"] == nil
            return first ? .json(200, page) : .json(200, #"{"rows": []}"#)
        }
        let rows = try await ApiSyncTransport(api: server.client(), pageSize: 1).pullWorkoutMeasurements(since: nil)
        #expect(rows.map(\.workoutId) == [UUID(uuidString: id)!])
        #expect(rows.first?.recordedBy == .watch && rows.first?.effortEstimated == false)
        #expect(server.requests.last?.query["after"] == id)
    }
}
