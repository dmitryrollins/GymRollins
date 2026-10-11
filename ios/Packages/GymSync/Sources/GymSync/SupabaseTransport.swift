import Foundation
import GymData
import Supabase

/// `SyncTransport` over PostgREST via supabase-swift. Deliberately thin: payloads are encoded with `SyncJSON`
/// (microsecond UTC timestamps, explicit nulls) and handed to the client as `AnyJSON`, and responses are decoded
/// from the raw body with `SyncJSON.decoder`, so behavior doesn't depend on the client's coder configuration.
/// RLS scopes every query to the signed-in user.
public struct SupabaseTransport: SyncTransport {
    public static let defaultPageSize = 500
    static let pushBatchSize = 200
    static let workoutSelect = "*,workout_entries(*,workout_sets(*))"

    private let client: SupabaseClient
    private let pageSize: Int

    /// `pageSize` is the pull page size (tests use a small one to exercise paging).
    public init(client: SupabaseClient, pageSize: Int = SupabaseTransport.defaultPageSize) {
        self.client = client
        self.pageSize = max(1, pageSize)
    }

    // MARK: Push

    public func push(profile: ProfileDTO) async throws -> RowAck? {
        let rows: [StampedRow] = try await upsert([profile], into: "profiles", onConflict: "user_id",
                                                  returning: "user_id,updated_at")
        return rows.first.map { RowAck(id: SyncStore.profileSyncID, updatedAt: $0.updatedAt) }
    }

    public func push(customExercises: [CustomExerciseDTO]) async throws -> [RowAck] {
        try await upsertAcks(customExercises, into: "custom_exercises")
    }

    public func push(exercisePrefs: [ExercisePrefDTO]) async throws -> [RowAck] {
        let rows: [PrefStampedRow] = try await upsert(exercisePrefs, into: "exercise_prefs",
                                                      onConflict: "user_id,exercise_id",
                                                      returning: "exercise_id,updated_at")
        return rows.map { RowAck(id: $0.exerciseId, updatedAt: $0.updatedAt) }
    }

    public func push(routines: [RoutineDTO]) async throws -> [RowAck] {
        try await upsertAcks(routines, into: "routines")
    }

    public func push(weekdays: [WeekdayDTO]) async throws -> [RowAck] {
        let rows: [StampedRow] = try await upsert(weekdays, into: "week_schedule", onConflict: "user_id,weekday",
                                                  returning: "weekday,updated_at")
        return rows.compactMap { row in row.weekday.map { RowAck(id: String($0), updatedAt: row.updatedAt) } }
    }

    public func push(muscleTargets: [MuscleTargetDTO]) async throws -> [RowAck] {
        let rows: [StampedRow] = try await upsert(muscleTargets, into: "muscle_targets", onConflict: "user_id,muscle",
                                                  returning: "muscle,updated_at")
        return rows.compactMap { row in row.muscle.map { RowAck(id: $0, updatedAt: row.updatedAt) } }
    }

    public func push(bodyweight: [BodyweightDTO]) async throws -> [RowAck] {
        try await upsertAcks(bodyweight, into: "bodyweight")
    }

    public func push(workout: WorkoutDTO) async throws -> WorkoutPushResult {
        let params: [String: AnyJSON] = ["payload": try Self.anyJSON(workout)]
        let data = try await Self.mappingRejections { try await client.rpc("upsert_workout", params: params).execute().data }
        return try SyncJSON.decoder.decode(WorkoutPushResult.self, from: data)
    }

    // MARK: Pull

    public func pullProfile(since: Date?) async throws -> [ProfileDTO] {
        try await pull("profiles", since: since, tiebreak: "user_id")
    }

    public func pullCustomExercises(since: Date?) async throws -> [CustomExerciseDTO] {
        try await pull("custom_exercises", since: since)
    }

    public func pullExercisePrefs(since: Date?) async throws -> [ExercisePrefDTO] {
        try await pull("exercise_prefs", since: since, tiebreak: "exercise_id")
    }

    public func pullRoutines(since: Date?) async throws -> [RoutineDTO] {
        try await pull("routines", since: since)
    }

    public func pullWeekdays(since: Date?) async throws -> [WeekdayDTO] {
        try await pull("week_schedule", since: since, tiebreak: "weekday")
    }

    public func pullMuscleTargets(since: Date?) async throws -> [MuscleTargetDTO] {
        try await pull("muscle_targets", since: since, tiebreak: "muscle")
    }

    public func pullBodyweight(since: Date?) async throws -> [BodyweightDTO] {
        try await pull("bodyweight", since: since)
    }

    public func pullWorkouts(since: Date?) async throws -> [WorkoutDTO] {
        try await pull("workouts", select: Self.workoutSelect, since: since)
    }

    public func fetchWorkout(id: UUID) async throws -> WorkoutDTO? {
        let data = try await client.from("workouts").select(Self.workoutSelect)
            .eq("id", value: id.uuidString.lowercased()).execute().data
        return try SyncJSON.decoder.decode([WorkoutDTO].self, from: data).first
    }

    // MARK: Proposals

    public func pendingProposals() async throws -> [PulledProposal] {
        let data = try await client.from("proposals").select().eq("status", value: "pending")
            .order("created_at").execute().data
        return try SyncJSON.decoder.decode([PulledProposal].self, from: data)
    }

    public func resolveProposal(id: UUID, status: String, appliedChangeIds: [String], at: Date) async throws {
        let stamp = AnyJSON.string(SyncDate.format(at))
        let values: [String: AnyJSON] = [
            "status": .string(status),
            "applied_change_ids": .array(appliedChangeIds.map(AnyJSON.string)),
            "resolved_at": stamp,
            "client_updated_at": stamp,
        ]
        _ = try await Self.mappingRejections {
            try await client.from("proposals").update(values, returning: .minimal)
                .eq("id", value: id.uuidString.lowercased()).execute().data
        }
    }

    public func lastMcpUse() async throws -> Date? {
        let data = try await client.from("mcp_audit").select("at").order("at", ascending: false).limit(1)
            .execute().data
        return try SyncJSON.decoder.decode([AuditRow].self, from: data).first?.at
    }

    /// Auth's user-grants API (`GET`/`DELETE /auth/v1/user/oauth/grants`). Revoking deletes the client's sessions
    /// and refresh tokens: it can't refresh, and Auth rejects its access token at once (so the MCP endpoint, which
    /// verifies tokens with Auth, refuses it). Only direct PostgREST use of that stateless JWT stays possible until
    /// it expires — the app turns every Claude permission off first, which RLS enforces for such a token.
    public func revokeOAuthGrants() async throws -> Int {
        let grants = try await client.auth.oauthServer.listGrants()
        for grant in grants { try await client.auth.oauthServer.revokeGrant(clientId: grant.client.id) }
        return grants.count
    }

    // MARK: - Helpers

    private func upsertAcks<T: Encodable>(_ rows: [T], into table: String) async throws -> [RowAck] {
        let stamped: [StampedRow] = try await upsert(rows, into: table, onConflict: "id", returning: "id,updated_at")
        return stamped.compactMap { row in row.id.map { RowAck(id: $0, updatedAt: row.updatedAt) } }
    }

    private func upsert<T: Encodable, R: Decodable>(_ rows: [T], into table: String, onConflict: String,
                                                    returning columns: String) async throws -> [R] {
        var acks: [R] = []
        for start in stride(from: 0, to: rows.count, by: Self.pushBatchSize) {
            let batch = Array(rows[start..<min(start + Self.pushBatchSize, rows.count)])
            let payload = try Self.anyJSON(batch)
            let data = try await Self.mappingRejections {
                try await client.from(table).upsert(payload, onConflict: onConflict).select(columns).execute().data
            }
            acks += try SyncJSON.decoder.decode([R].self, from: data)
        }
        return acks
    }

    /// All rows with `updated_at > since`, keyset-paged by `(updated_at, tiebreak)` (see `KeysetPager`). Rows
    /// written in one statement share `updated_at`, which is why the tiebreak is part of the key.
    private func pull<T: Decodable>(_ table: String, select: String = "*", since: Date?,
                                    tiebreak: String = "id") async throws -> [T] {
        try await KeysetPager.collect(pageSize: pageSize, since: since) { after, since, limit in
            var query = client.from(table).select(select)
            if let after {
                query = query.or(Self.afterFilter(after, tiebreak: tiebreak))
            } else if let since {
                query = query.gt("updated_at", value: SyncDate.format(since))
            }
            let data = try await query.order("updated_at").order(tiebreak).limit(limit).execute().data
            let rows = try SyncJSON.decoder.decode([T].self, from: data)
            let keys = try PageKey.decode(data, tiebreak: tiebreak)
            guard rows.count == keys.count else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Page keys don't match rows"))
            }
            return Array(zip(rows, keys)).map { (row: $0, key: $1) }
        }
    }

    /// PostgREST `or` filter for "after this key": `updated_at > t OR (updated_at = t AND tiebreak > k)`. Values
    /// are double-quoted because timestamps contain reserved characters (`.`, `:`).
    static func afterFilter(_ key: PageKey, tiebreak: String) -> String {
        let t = SyncDate.format(key.updatedAt)
        return "updated_at.gt.\"\(t)\",and(updated_at.eq.\"\(t)\",\(tiebreak).gt.\"\(key.tiebreak)\")"
    }

    /// Rethrows a PostgREST error about the row's data (SQLSTATE 22xxx/23xxx) as `SyncRecordRejected`.
    private static func mappingRejections<R>(_ call: () async throws -> R) async throws -> R {
        do {
            return try await call()
        } catch let error as PostgrestError where SyncRecordRejected.isRowRejection(code: error.code) {
            throw SyncRecordRejected(code: error.code ?? "", message: error.message)
        }
    }

    static func anyJSON<T: Encodable>(_ value: T) throws -> AnyJSON {
        try JSONDecoder().decode(AnyJSON.self, from: SyncJSON.encoder.encode(value))
    }
}

/// Key + server time returned by an upsert (`id`, `weekday` or `muscle`, depending on the table).
private struct StampedRow: Decodable {
    let id: String?
    let weekday: Int?
    let muscle: String?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey { case id, weekday, muscle, updatedAt = "updated_at" }
}

/// Key + server time returned by an `exercise_prefs` upsert.
private struct PrefStampedRow: Decodable {
    let exerciseId: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey { case exerciseId = "exercise_id", updatedAt = "updated_at" }
}

private struct AuditRow: Decodable { let at: Date }
