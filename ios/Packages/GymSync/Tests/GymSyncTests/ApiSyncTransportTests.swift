import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// `ApiSyncTransport` against a stub of `/v1/sync`: the bodies, queries and answers of server/src/sync/routes.ts.
@Suite struct ApiSyncTransportTests {
    private let t0 = SyncDate.parse("2026-09-27T08:00:00.123456Z")!

    private func rows(_ request: SeenRequest) -> [[String: Any]] {
        ((try? request.json()) as? [String: Any])?["rows"] as? [[String: Any]] ?? []
    }

    @Test func rowsGoUpUnderRowsAndComeBackAsAcks() async throws {
        let routine = Routine(name: "Push", exercises: [])
        let id = routine.id.uuidString.lowercased()
        let answer = #"{"acks": [{"id": "\#(id)", "updated_at": "2026-11-08T10:00:00.123000Z"}]}"#
        let server = StubServer { _ in .json(200, answer) }
        let dto = RoutineDTO(SyncRow(value: RoutineSnapshot(routine: routine, position: 0), clientUpdatedAt: t0))

        let acks = try await ApiSyncTransport(api: server.client()).push(routines: [dto])

        #expect(acks == [RowAck(id: id, updatedAt: SyncDate.parse("2026-11-08T10:00:00.123Z")!)])
        let request = try #require(server.requests.first)
        #expect(request.method == "POST" && request.path == "/v1/sync/routines")
        #expect(rows(request).first?["name"] as? String == "Push")
        #expect(rows(request).first?["client_updated_at"] as? String == "2026-09-27T08:00:00.123456Z")
    }

    @Test func everyTablePullsFromItsOwnPath() async throws {
        let server = StubServer { _ in .json(200, #"{"rows": []}"#) }
        let transport = ApiSyncTransport(api: server.client())
        _ = try await transport.pullProfile(since: nil)
        _ = try await transport.pullCustomExercises(since: nil)
        _ = try await transport.pullExercisePrefs(since: nil)
        _ = try await transport.pullRoutines(since: nil)
        _ = try await transport.pullWeekdays(since: nil)
        _ = try await transport.pullMuscleTargets(since: nil)
        _ = try await transport.pullBodyweight(since: nil)
        _ = try await transport.pullWorkouts(since: nil)
        #expect(server.requests.map(\.path) == [
            "/v1/sync/profile", "/v1/sync/custom-exercises", "/v1/sync/exercise-prefs", "/v1/sync/routines",
            "/v1/sync/weekdays", "/v1/sync/muscle-targets", "/v1/sync/bodyweight", "/v1/sync/workouts",
        ])
        #expect(server.requests.map { $0.query["limit"] ?? "" } == Array(repeating: "500", count: 7) + ["50"])
    }

    @Test func theProfileAckIsTheProfilesFixedId() async throws {
        let accountId = "b73f3bdc-18c8-400a-b492-4db321b4baee"
        let server = StubServer { _ in
            .json(200, #"{"acks": [{"id": "\#(accountId)", "updated_at": "2026-11-08T10:00:00.123000Z"}]}"#)
        }
        let profile = ProfileDTO(SyncRow(value: ProfileSnapshot(), clientUpdatedAt: t0))
        #expect(try await ApiSyncTransport(api: server.client()).push(profile: profile)?.id == SyncStore.profileSyncID)
        #expect(server.requests.first?.path == "/v1/sync/profile")
        let keptNewer = StubServer { _ in .json(200, #"{"acks": []}"#) }
        #expect(try await ApiSyncTransport(api: keptNewer.client()).push(profile: profile) == nil)
    }

    @Test func pushesGoUpTwoHundredRowsAtATime() async throws {
        let server = StubServer { _ in .json(200, #"{"acks": []}"#) }
        let entries = (0..<450).map {
            BodyweightDTO(SyncRow(value: BodyweightEntry(date: t0 + Double($0), weightKg: 80), clientUpdatedAt: t0))
        }
        _ = try await ApiSyncTransport(api: server.client()).push(bodyweight: entries)
        #expect(server.requests.map { rows($0).count } == [200, 200, 50])
        #expect(server.requests.allSatisfy { $0.path == "/v1/sync/bodyweight" })
    }

    @Test func pullsPageBySinceAfterAndLimitUntilAShortPage() async throws {
        // Five weigh-ins, the first three written by one statement (one stamp), served in the server's keyset order.
        let stamps = ["2026-11-08T10:00:00.100000Z", "2026-11-08T10:00:00.100000Z", "2026-11-08T10:00:00.100000Z",
                      "2026-11-08T10:00:00.200000Z", "2026-11-08T10:00:00.300000Z"]
        let ids = (1...5).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
        let stored = Array(zip(ids, stamps))
        let server = StubServer { request in
            let since = request.query["since"], after = request.query["after"]
            let limit = Int(request.query["limit"] ?? "") ?? 500
            let page = stored.filter { id, at in
                guard let since else { return true }
                guard let after else { return at > since }
                return at > since || (at == since && id > after)
            }.prefix(limit).map { id, at in
                #"{"id": "\#(id)", "measured_at": "2026-09-27T08:00:00.000000Z", "w_kg": 80, "bf_pct": null, "t": null, "#
                    + #""source": null, "health_sample_id": null, "health_fat_sample_id": null, "#
                    + #""client_updated_at": "2026-09-27T08:00:00.000000Z", "deleted_at": null, "updated_at": "\#(at)"}"#
            }
            return .json(200, #"{"rows": [\#(page.joined(separator: ","))]}"#)
        }

        let pulled = try await ApiSyncTransport(api: server.client(), pageSize: 2).pullBodyweight(since: nil)

        #expect(pulled.map { $0.id.uuidString.lowercased() } == ids)
        #expect(server.requests.map(\.query) == [
            ["limit": "2"],
            ["limit": "2", "since": stamps[1], "after": ids[1]],
            ["limit": "2", "since": stamps[3], "after": ids[3]],
        ])
    }

    @Test func theWeekdayTiebreakGoesUpAsANumber() async throws {
        let server = StubServer { request in
            let rows = request.query["after"] == nil
                ? #"[{"weekday": 3, "routine_id": null, "client_updated_at": "2026-09-27T08:00:00.000000Z", "#
                    + #""updated_at": "2026-11-08T10:00:00.100000Z"}]"#
                : "[]"
            return .json(200, #"{"rows": \#(rows)}"#)
        }
        _ = try await ApiSyncTransport(api: server.client(), pageSize: 1).pullWeekdays(since: nil)
        #expect(server.requests.last?.query["after"] == "3")
    }

    @Test func aWorkoutGoesUpAloneWithItsBaseVersionAndEntries() async throws {
        let server = StubServer { _ in .json(200, #"{"status": "stale", "updated_at": "2026-11-08T10:00:00.100000Z"}"#) }
        let workout = Workout(startedAt: t0, endedAt: t0 + 600, name: "Push", entries: [
            WorkoutEntry(exerciseId: "bench", sets: [WorkoutSet(weightKg: 60, reps: 8, done: true)]),
        ])
        let base = SyncDate.parse("2026-11-07T09:00:00.000001Z")!
        let dto = WorkoutDTO(SyncRow(value: WorkoutSnapshot(workout: workout, records: [], volumeKg: 480),
                                     clientUpdatedAt: t0 + 600, serverUpdatedAt: base))

        let result = try await ApiSyncTransport(api: server.client()).push(workout: dto)

        #expect(result == .stale(updatedAt: SyncDate.parse("2026-11-08T10:00:00.1Z")!))
        let request = try #require(server.requests.first)
        #expect(request.method == "POST" && request.path == "/v1/sync/workouts")
        let body = try #require(try request.json() as? [String: Any])
        #expect(body["id"] as? String == workout.id.uuidString)
        #expect(body["base_updated_at"] as? String == "2026-11-07T09:00:00.000001Z")
        #expect(body["force"] as? Bool == false)
        let entries = try #require(body["entries"] as? [[String: Any]])
        #expect((entries.first?["sets"] as? [Any])?.count == 1)
    }

    @Test func fetchingAMissingWorkoutIsNil() async throws {
        let server = StubServer { _ in .json(404, #"{"error": {"code": "not_found", "message": "No such workout."}}"#) }
        let id = UUID()
        #expect(try await ApiSyncTransport(api: server.client()).fetchWorkout(id: id) == nil)
        #expect(server.requests.first?.path == "/v1/sync/workouts/\(id.uuidString.lowercased())")
    }

    @Test func refusedRowsBecomeRowRejectionsAndTheRestEndsTheRound() async throws {
        let row = BodyweightDTO(SyncRow(value: BodyweightEntry(date: t0, weightKg: 500), clientUpdatedAt: t0))
        func push(_ status: Int, _ code: String, _ message: String) async throws {
            let server = StubServer { _ in .json(status, #"{"error": {"code": "\#(code)", "message": "\#(message)"}}"#) }
            _ = try await ApiSyncTransport(api: server.client()).push(bodyweight: [row])
        }
        await #expect(throws: SyncRecordRejected(code: "row_rejected",
                                                 message: "CHECK constraint failed: w_kg BETWEEN 30 AND 300")) {
            try await push(422, "row_rejected", "CHECK constraint failed: w_kg BETWEEN 30 AND 300")
        }
        await #expect(throws: SyncRecordRejected(code: "not_allowed",
                                                 message: "This belongs to another account and can't be synced.")) {
            try await push(403, "not_allowed", "That row belongs to another account.")
        }
        await #expect(throws: SyncRecordRejected(code: "too_large", message: "The request body is too large.")) {
            try await push(413, "too_large", "The request body is too large.")
        }
        await #expect(throws: ApiError(status: 401, code: "signed_out", message: "Sign in required.")) {
            try await push(401, "signed_out", "Sign in required.")
        }
        await #expect(throws: ApiError(status: 503, code: "server_error", message: "Something went wrong.")) {
            try await push(503, "server_error", "Something went wrong.")
        }
    }

    @Test func itServesNeitherGymsNorProposalsYet() async throws {
        let server = StubServer { _ in .json(500, "{}") }
        let transport = ApiSyncTransport(api: server.client())
        #expect(!transport.servesGyms && !transport.servesProposals)
        #expect(try await transport.pendingProposals().isEmpty)
        #expect(server.requests.isEmpty)
    }
}
