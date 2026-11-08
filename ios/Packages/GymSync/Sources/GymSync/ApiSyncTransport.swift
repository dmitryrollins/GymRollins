import Foundation
import GymData

/// `SyncTransport` over the API's `/v1/sync` (server/src/sync/routes.ts; spec section 3, "Routes"). The server scopes
/// every call to the session's account.
/// - Rows go up as `POST /v1/sync/<entity>` `{"rows": [...]}`, 200 a request, and the answer acks the rows
///   stored. A row the server's last-write-wins skipped gets no ack, as with `lww_guard`.
/// - Pulls are keyset pages, `GET /v1/sync/<entity>?since&after&limit` answered `{"rows": [...]}`: `since` alone means
///   newer than it; with `after`, the rows after `(since, after)` in `(updated_at, tiebreak)` order.
/// - A workout goes up alone, with its entries, sets and base version, and is answered `{"status", "updated_at"}`.
///   Pulled workouts carry `entries[].sets[]`, so their pages are smaller.
///
/// Private gyms, their listings and their photos are on the API since plan 28 (`ApiSyncTransport+Gyms.swift`). Claude's
/// proposals aren't until plan 29, so `servesProposals` is false and the engine leaves them out; Claude's last use and
/// grants keep the protocol's defaults (never used, nothing to revoke).
public struct ApiSyncTransport: SyncTransport {
    public static let defaultPageSize = 500
    /// A workout page carries every entry and set. The owner averages 6 entries and 18 sets a workout, so 50 workouts
    /// are about a thousand rows: small enough for one request within the Worker's free-plan CPU time.
    public static let defaultWorkoutPageSize = 50
    static let pushBatchSize = 200
    /// What a refused row says when another account holds its id (403 `not_allowed`).
    static let notYoursMessage = "This belongs to another account and can't be synced."

    let api: ApiClient
    private let pageSize: Int
    private let workoutPageSize: Int

    /// The page sizes are for tests, which use small ones to exercise paging.
    public init(api: ApiClient, pageSize: Int = ApiSyncTransport.defaultPageSize,
                workoutPageSize: Int = ApiSyncTransport.defaultWorkoutPageSize) {
        self.api = api
        self.pageSize = max(1, pageSize)
        self.workoutPageSize = max(1, workoutPageSize)
    }

    public var servesGyms: Bool { true }
    public var servesProposals: Bool { false }

    // MARK: Push

    public func push(profile: ProfileDTO) async throws -> RowAck? {
        // The server's ack id is the account's id; the engine knows the profile by its fixed id.
        try await push([profile], to: "profile").first
            .map { RowAck(id: SyncStore.profileSyncID, updatedAt: $0.updatedAt) }
    }

    public func push(customExercises: [CustomExerciseDTO]) async throws -> [RowAck] {
        try await push(customExercises, to: "custom-exercises")
    }

    public func push(exercisePrefs: [ExercisePrefDTO]) async throws -> [RowAck] {
        try await push(exercisePrefs, to: "exercise-prefs")
    }

    public func push(routines: [RoutineDTO]) async throws -> [RowAck] {
        try await push(routines, to: "routines")
    }

    public func push(weekdays: [WeekdayDTO]) async throws -> [RowAck] {
        try await push(weekdays, to: "weekdays")
    }

    public func push(muscleTargets: [MuscleTargetDTO]) async throws -> [RowAck] {
        try await push(muscleTargets, to: "muscle-targets")
    }

    public func push(bodyweight: [BodyweightDTO]) async throws -> [RowAck] {
        try await push(bodyweight, to: "bodyweight")
    }

    public func push(workout: WorkoutDTO) async throws -> WorkoutPushResult {
        try await Self.mappingRejections { try await api.post("/v1/sync/workouts", workout) }
    }

    // MARK: Pull

    public func pullProfile(since: Date?) async throws -> [ProfileDTO] {
        try await pull("profile", tiebreak: "user_id", since: since)
    }

    public func pullCustomExercises(since: Date?) async throws -> [CustomExerciseDTO] {
        try await pull("custom-exercises", tiebreak: "id", since: since)
    }

    public func pullExercisePrefs(since: Date?) async throws -> [ExercisePrefDTO] {
        try await pull("exercise-prefs", tiebreak: "exercise_id", since: since)
    }

    public func pullRoutines(since: Date?) async throws -> [RoutineDTO] {
        try await pull("routines", tiebreak: "id", since: since)
    }

    public func pullWeekdays(since: Date?) async throws -> [WeekdayDTO] {
        try await pull("weekdays", tiebreak: "weekday", since: since)
    }

    public func pullMuscleTargets(since: Date?) async throws -> [MuscleTargetDTO] {
        try await pull("muscle-targets", tiebreak: "muscle", since: since)
    }

    public func pullBodyweight(since: Date?) async throws -> [BodyweightDTO] {
        try await pull("bodyweight", tiebreak: "id", since: since)
    }

    public func pullWorkouts(since: Date?) async throws -> [WorkoutDTO] {
        try await pull("workouts", tiebreak: "id", pageSize: workoutPageSize, since: since)
    }

    public func fetchWorkout(id: UUID) async throws -> WorkoutDTO? {
        do {
            return try await api.get("/v1/sync/workouts/\(id.uuidString.lowercased())")
        } catch let error as ApiError where error.status == 404 {
            return nil
        }
    }

    // MARK: Not on the API yet (plan 29)

    /// Never called while `servesProposals` is false.
    public func pendingProposals() async throws -> [PulledProposal] { [] }

    /// Never called while `servesProposals` is false; if it were, the resolution would stay unsent rather than count
    /// as sent.
    public func resolveProposal(id: UUID, status: String, appliedChangeIds: [String], at: Date) async throws {
        throw ApiError(status: 404, code: "not_found", message: "Proposals aren't on this server yet.")
    }

    // MARK: - Helpers

    func push<Row: Encodable>(_ rows: [Row], to entity: String) async throws -> [RowAck] {
        var acks: [RowAck] = []
        for start in stride(from: 0, to: rows.count, by: Self.pushBatchSize) {
            let batch = Array(rows[start..<min(start + Self.pushBatchSize, rows.count)])
            let answer: AckList = try await Self.mappingRejections {
                try await api.post("/v1/sync/\(entity)", RowList(rows: batch))
            }
            acks += answer.acks.map { RowAck(id: $0.id, updatedAt: $0.updatedAt) }
        }
        return acks
    }

    func pull<Row: Decodable>(_ entity: String, tiebreak: String, pageSize: Int? = nil,
                                      since: Date?) async throws -> [Row] {
        try await KeysetPager.collect(pageSize: pageSize ?? self.pageSize, since: since) { after, since, limit in
            var query = [URLQueryItem(name: "limit", value: String(limit))]
            if let after {
                query.append(URLQueryItem(name: "since", value: SyncDate.format(after.updatedAt)))
                query.append(URLQueryItem(name: "after", value: after.tiebreak))
            } else if let since {
                query.append(URLQueryItem(name: "since", value: SyncDate.format(since)))
            }
            let (body, _) = try await api.data("GET", "/v1/sync/\(entity)", query: query)
            let rows = try SyncJSON.decoder.decode(RowList<Row>.self, from: body).rows
            let keys = try PageKey.decode(body, tiebreak: tiebreak)
            guard rows.count == keys.count else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Page keys don't match rows"))
            }
            return Array(zip(rows, keys)).map { (row: $0, key: $1) }
        }
    }

    /// A row refused for its values (422, `row_rejected`: a CHECK, a foreign key or a wrong type), for an id another
    /// account holds (403 `not_allowed`), or for being too big (413 `too_large`) is about that row alone: the engine
    /// records it and syncs the rest, as with SQLSTATE 22/23. Anything else (signed out, server trouble) ends the
    /// round.
    static func mappingRejections<R>(_ call: () async throws -> R) async throws -> R {
        do {
            return try await call()
        } catch let error as ApiError {
            switch error.code {
            case "not_allowed": throw SyncRecordRejected(code: error.code, message: notYoursMessage)
            case "row_rejected", "too_large": throw SyncRecordRejected(code: error.code, message: error.message)
            default: throw error.status == 422 ? SyncRecordRejected(code: error.code, message: error.message) : error
            }
        }
    }
}

/// `{"rows": [...]}`: what a push sends and a pull answers.
private struct RowList<Row> {
    let rows: [Row]
}

extension RowList: Encodable where Row: Encodable {}
extension RowList: Decodable where Row: Decodable {}

/// `{"acks": [{"id", "updated_at"}]}`.
private struct AckList: Decodable {
    struct Ack: Decodable {
        let id: String
        let updatedAt: Date

        enum CodingKeys: String, CodingKey { case id, updatedAt = "updated_at" }
    }

    let acks: [Ack]
}
