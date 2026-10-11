import Foundation
import GymData
@testable import GymSync

/// In-memory server mirroring the SQL rules: `updated_at` is stamped on every accepted write (strictly
/// increasing), upserts older than the stored `client_updated_at` are skipped without an ack (the `lww_guard`
/// trigger), and `upsert_workout` answers `stale` instead. Every payload passes through the JSON wire format.
actor FakeTransport: SyncTransport {
    private(set) var profile: ProfileDTO?
    private(set) var customExercises: [String: CustomExerciseDTO] = [:]
    private(set) var exercisePrefs: [String: ExercisePrefDTO] = [:]
    private(set) var routines: [UUID: RoutineDTO] = [:]
    private(set) var weekdays: [Int: WeekdayDTO] = [:]
    private(set) var muscleTargets: [String: MuscleTargetDTO] = [:]
    private(set) var bodyweight: [UUID: BodyweightDTO] = [:]
    private(set) var workouts: [UUID: WorkoutDTO] = [:]
    private(set) var proposals: [UUID: ProposalDTO] = [:]
    private var malformedProposals: [UUID: String] = [:]
    private(set) var grants: [UUID] = []
    private(set) var revokedGrants: [UUID] = []

    private(set) var pushCalls = 0
    /// The `base_updated_at` of the last workout push (`.some(nil)` = sent without a base) and forced pushes.
    private(set) var lastWorkoutBase: Date??
    private(set) var forcedWorkoutPushes = 0
    private(set) var pulledRows = 0
    private var serverClock = SyncDate.parse("2026-09-27T00:00:00Z")!
    private var failure: URLError?
    /// Lowercased ids the "database" refuses with a CHECK violation (the whole batch fails, like Postgres).
    private var rejected: Set<String> = []
    private var holdPulls = false
    private var heldPull: CheckedContinuation<Void, Never>?

    func fail(with error: URLError?) { failure = error }
    func reject(ids: [String]) { rejected = Set(ids.map { $0.lowercased() }) }

    /// The next pull suspends until `releasePull()` (to overlap a round with sign-out).
    func holdNextPull() { holdPulls = true }
    var isPullSuspended: Bool { heldPull != nil }
    func releasePull() {
        heldPull?.resume()
        heldPull = nil
    }

    private func waitIfHeld() async {
        guard holdPulls else { return }
        holdPulls = false
        await withCheckedContinuation { heldPull = $0 }
    }

    private func checkRejected(_ ids: [String]) throws {
        if let bad = ids.first(where: { rejected.contains($0.lowercased()) }) {
            throw SyncRecordRejected(code: "23514", message: "new row violates check constraint (\(bad))")
        }
    }

    // MARK: Test hooks ("another device")

    func seed(routine: RoutineDTO) throws { _ = try accept(routine, into: &routines, key: routine.id) }
    func seed(exercisePref dto: ExercisePrefDTO) throws { _ = try accept(dto, into: &exercisePrefs, key: dto.exerciseId) }
    func seed(muscleTarget dto: MuscleTargetDTO) throws { _ = try accept(dto, into: &muscleTargets, key: dto.muscle) }
    func seed(bodyweight entry: BodyweightDTO) throws { _ = try accept(entry, into: &bodyweight, key: entry.id) }
    /// Another device's accepted write (it saw the current version): stored whatever the base.
    func seed(profile dto: ProfileDTO) throws { profile = try stamp(dto) }
    func seed(workout: WorkoutDTO) throws {
        var forced = workout
        forced.force = true
        _ = try store(workout: forced)
    }
    func seed(proposal: ProposalDTO) { proposals[proposal.id] = proposal }
    /// OAuth clients the user has granted access (e.g. Claude's connector).
    func seed(grants clientIds: [UUID]) { grants = clientIds }
    /// A pending row the app's strict decoder refuses (`changes` is raw JSON), as the server may hold.
    func seed(malformedProposal id: UUID, createdAt: Date, changes: String) {
        let stamp = SyncDate.format(createdAt)
        malformedProposals[id] = #"{"id":"\#(id.uuidString.lowercased())","created_at":"\#(stamp)","#
            + #""summary":"Bad","status":"pending","changes":\#(changes)}"#
    }
    func drop(malformedProposal id: UUID) { malformedProposals[id] = nil }

    // MARK: Push

    func push(profile dto: ProfileDTO) throws -> RowAck? {
        try gate()
        if let old = profile, dto.clientUpdatedAt < old.clientUpdatedAt { return nil }
        let stored = try stamp(dto)
        profile = stored
        return RowAck(id: SyncStore.profileSyncID, updatedAt: stored.updatedAt!)
    }

    func push(customExercises dtos: [CustomExerciseDTO]) throws -> [RowAck] {
        try gate()
        try checkRejected(dtos.map(\.id))
        return try dtos.compactMap { dto in
            try accept(dto, into: &customExercises, key: dto.id).map { RowAck(id: $0.id, updatedAt: $0.updatedAt!) }
        }
    }

    func push(exercisePrefs dtos: [ExercisePrefDTO]) throws -> [RowAck] {
        try gate()
        try checkRejected(dtos.map(\.exerciseId))
        return try dtos.compactMap { dto in
            try accept(dto, into: &exercisePrefs, key: dto.exerciseId)
                .map { RowAck(id: $0.exerciseId, updatedAt: $0.updatedAt!) }
        }
    }

    func push(routines dtos: [RoutineDTO]) throws -> [RowAck] {
        try gate()
        try checkRejected(dtos.map(\.id.uuidString))
        return try dtos.compactMap { dto in
            try accept(dto, into: &routines, key: dto.id).map { RowAck(id: $0.id.uuidString.lowercased(), updatedAt: $0.updatedAt!) }
        }
    }

    func push(weekdays dtos: [WeekdayDTO]) throws -> [RowAck] {
        try gate()
        return try dtos.compactMap { dto in
            try accept(dto, into: &weekdays, key: dto.weekday).map { RowAck(id: String($0.weekday), updatedAt: $0.updatedAt!) }
        }
    }

    func push(muscleTargets dtos: [MuscleTargetDTO]) throws -> [RowAck] {
        try gate()
        return try dtos.compactMap { dto in
            try accept(dto, into: &muscleTargets, key: dto.muscle).map { RowAck(id: $0.muscle, updatedAt: $0.updatedAt!) }
        }
    }

    func push(bodyweight dtos: [BodyweightDTO]) throws -> [RowAck] {
        try gate()
        try checkRejected(dtos.map(\.id.uuidString))
        return try dtos.compactMap { dto in
            try accept(dto, into: &bodyweight, key: dto.id).map { RowAck(id: $0.id.uuidString.lowercased(), updatedAt: $0.updatedAt!) }
        }
    }

    func push(workout dto: WorkoutDTO) throws -> WorkoutPushResult {
        try gate()
        try checkRejected([dto.id.uuidString])
        let sent = try wire(dto)
        lastWorkoutBase = .some(sent.baseUpdatedAt)
        if sent.force { forcedWorkoutPushes += 1 }
        return try store(workout: sent)
    }

    /// `upsert_workout`'s rules: unless forced, a base other than the stored version (a null base is accepted only
    /// as a retry of the same edit) or an older edit time is `stale`; a forced write keeps the newer edit time.
    private func store(workout dto: WorkoutDTO) throws -> WorkoutPushResult {
        var incoming = dto
        if let old = workouts[dto.id] {
            if !dto.force {
                let retry = dto.baseUpdatedAt == nil && old.clientUpdatedAt == dto.clientUpdatedAt
                if old.updatedAt != dto.baseUpdatedAt && !retry { return .stale(updatedAt: old.updatedAt!) }
                if old.clientUpdatedAt > dto.clientUpdatedAt { return .stale(updatedAt: old.updatedAt!) }
            } else if old.clientUpdatedAt > dto.clientUpdatedAt {
                incoming = try WorkoutDTO.restamped(dto, clientUpdatedAt: old.clientUpdatedAt)
            }
        }
        var stored = try stamp(incoming)
        stored.baseUpdatedAt = nil
        stored.force = false
        workouts[dto.id] = stored
        return .ok(updatedAt: stored.updatedAt!)
    }

    // MARK: Pull

    func pullProfile(since: Date?) async throws -> [ProfileDTO] {
        await waitIfHeld()
        return try pull([profile].compactMap { $0 }, since: since)
    }
    func pullCustomExercises(since: Date?) async throws -> [CustomExerciseDTO] {
        await waitIfHeld()
        return try pull(Array(customExercises.values), since: since)
    }
    func pullExercisePrefs(since: Date?) async throws -> [ExercisePrefDTO] {
        await waitIfHeld()
        return try pull(Array(exercisePrefs.values), since: since)
    }
    func pullRoutines(since: Date?) async throws -> [RoutineDTO] {
        await waitIfHeld()
        return try pull(Array(routines.values), since: since)
    }
    func pullWeekdays(since: Date?) async throws -> [WeekdayDTO] {
        await waitIfHeld()
        return try pull(Array(weekdays.values), since: since)
    }
    func pullMuscleTargets(since: Date?) async throws -> [MuscleTargetDTO] {
        await waitIfHeld()
        return try pull(Array(muscleTargets.values), since: since)
    }
    func pullBodyweight(since: Date?) async throws -> [BodyweightDTO] {
        await waitIfHeld()
        return try pull(Array(bodyweight.values), since: since)
    }
    func pullWorkouts(since: Date?) async throws -> [WorkoutDTO] {
        await waitIfHeld()
        return try pull(Array(workouts.values), since: since)
    }

    func fetchWorkout(id: UUID) throws -> WorkoutDTO? {
        try gate()
        return workouts[id]
    }

    /// Decoded from JSON like the real transport, so malformed rows come back as `.malformed`.
    func pendingProposals() async throws -> [PulledProposal] {
        await waitIfHeld()
        if let failure { throw failure } // a pull: not counted in pushCalls
        let valid = try proposals.values.filter { $0.status == "pending" }.sorted { $0.createdAt < $1.createdAt }
            .map { String(decoding: try SyncJSON.encoder.encode($0), as: UTF8.self) }
        let body = "[" + (valid + malformedProposals.values).joined(separator: ",") + "]"
        return try SyncJSON.decoder.decode([PulledProposal].self, from: Data(body.utf8))
    }

    func resolveProposal(id: UUID, status: String, appliedChangeIds: [String], at: Date) throws {
        try gate()
        try checkRejected([id.uuidString])
        guard let p = proposals[id] else { return }
        proposals[id] = ProposalDTO(id: p.id, createdAt: p.createdAt, source: p.source, summary: p.summary,
                                    changes: p.changes, status: status, appliedChangeIds: appliedChangeIds,
                                    resolvedAt: at)
    }

    func revokeOAuthGrants() throws -> Int {
        try gate()
        let revoked = grants
        revokedGrants += revoked
        grants = []
        return revoked.count
    }

    // MARK: - Rules

    private func gate() throws {
        pushCalls += 1
        if let failure { throw failure }
    }

    /// LWW guard: skip (nil) when the stored edit is newer; otherwise store with a fresh `updated_at`.
    private func accept<K: Hashable, T: Codable & ServerStampedDTO>(_ dto: T, into table: inout [K: T], key: K) throws -> T? {
        if let old = table[key], dto.clientUpdatedAt < old.clientUpdatedAt { return nil }
        let stored = try stamp(dto)
        table[key] = stored
        return stored
    }

    private func stamp<T: Codable & ServerStampedDTO>(_ dto: T) throws -> T {
        serverClock = serverClock.addingTimeInterval(1)
        var stored = try wire(dto)
        stored.updatedAt = serverClock
        return stored
    }

    private func pull<T: Codable & ServerStampedDTO>(_ rows: [T], since: Date?) throws -> [T] {
        if let failure { throw failure }
        let result = try rows.filter { ($0.updatedAt ?? .distantPast) > (since ?? .distantPast) }
            .sorted { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
            .map { try wireKeepingStamp($0) }
        pulledRows += result.count
        return result
    }

    /// `updated_at` isn't encoded on push, so pulls carry it across the wire separately.
    private func wireKeepingStamp<T: Codable & ServerStampedDTO>(_ dto: T) throws -> T {
        var copy = try wire(dto)
        copy.updatedAt = dto.updatedAt
        return copy
    }
}

/// Test-side view of the DTOs' mutable server stamp.
protocol ServerStampedDTO: ServerStamped {
    var clientUpdatedAt: Date { get }
    var updatedAt: Date? { get set }
}

extension ProfileDTO: ServerStampedDTO {}
extension CustomExerciseDTO: ServerStampedDTO {}
extension ExercisePrefDTO: ServerStampedDTO {}
extension RoutineDTO: ServerStampedDTO {}
extension WeekdayDTO: ServerStampedDTO {}
extension MuscleTargetDTO: ServerStampedDTO {}
extension BodyweightDTO: ServerStampedDTO {}
extension WorkoutDTO: ServerStampedDTO {
    /// A copy with another `client_updated_at` (the SQL function's `greatest(...)` for forced writes).
    static func restamped(_ dto: WorkoutDTO, clientUpdatedAt: Date) throws -> WorkoutDTO {
        guard var json = try JSONSerialization.jsonObject(with: SyncJSON.encoder.encode(dto)) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        json["client_updated_at"] = SyncDate.format(clientUpdatedAt)
        return try SyncJSON.decoder.decode(WorkoutDTO.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
