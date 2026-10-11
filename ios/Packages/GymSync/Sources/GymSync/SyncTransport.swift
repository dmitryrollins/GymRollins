import Foundation

/// The server side of sync. Pushes return acks only for rows the server stored: a row skipped by the
/// last-write-wins guard (the server holds a newer edit) gets no ack and stays dirty until a pull replaces it.
/// Pulls return rows with `updated_at > since` (all rows when nil), oldest first.
public protocol SyncTransport: Sendable {
    /// Upserts the caller's profile; nil when the server kept a newer edit.
    func push(profile: ProfileDTO) async throws -> RowAck?
    func push(customExercises: [CustomExerciseDTO]) async throws -> [RowAck]
    /// Acks use the exercise id as id.
    func push(exercisePrefs: [ExercisePrefDTO]) async throws -> [RowAck]
    func push(routines: [RoutineDTO]) async throws -> [RowAck]
    /// Acks use the weekday number ("1"…"7") as id.
    func push(weekdays: [WeekdayDTO]) async throws -> [RowAck]
    /// Acks use the muscle id ("chest", "upper_back", …) as id.
    func push(muscleTargets: [MuscleTargetDTO]) async throws -> [RowAck]
    func push(bodyweight: [BodyweightDTO]) async throws -> [RowAck]
    /// `upsert_workout` RPC: replaces the workout and its entries/sets in one transaction.
    func push(workout: WorkoutDTO) async throws -> WorkoutPushResult

    func pullProfile(since: Date?) async throws -> [ProfileDTO]
    func pullCustomExercises(since: Date?) async throws -> [CustomExerciseDTO]
    func pullExercisePrefs(since: Date?) async throws -> [ExercisePrefDTO]
    func pullRoutines(since: Date?) async throws -> [RoutineDTO]
    func pullWeekdays(since: Date?) async throws -> [WeekdayDTO]
    func pullMuscleTargets(since: Date?) async throws -> [MuscleTargetDTO]
    func pullBodyweight(since: Date?) async throws -> [BodyweightDTO]
    func pullWorkouts(since: Date?) async throws -> [WorkoutDTO]
    /// One workout with its entries and sets (conflict resolution "Keep other"), or nil if absent.
    func fetchWorkout(id: UUID) async throws -> WorkoutDTO?

    /// Pending proposals, decoded per row: a row the app can't read comes back `.malformed`.
    func pendingProposals() async throws -> [PulledProposal]
    func resolveProposal(id: UUID, status: String, appliedChangeIds: [String], at: Date) async throws
    func lastMcpUse() async throws -> Date?
    /// Revokes every OAuth grant the signed-in user has given (the Claude connector is GymRollins' only OAuth
    /// client); returns how many were revoked.
    func revokeOAuthGrants() async throws -> Int
}

extension SyncTransport {
    /// Test doubles that predate weekly targets store none (no acks, nothing to pull).
    public func push(muscleTargets: [MuscleTargetDTO]) async throws -> [RowAck] { [] }
    public func pullMuscleTargets(since: Date?) async throws -> [MuscleTargetDTO] { [] }

    /// When Claude last called the MCP server for this user (newest `mcp_audit` row), nil if never.
    public func lastMcpUse() async throws -> Date? { nil }

    public func revokeOAuthGrants() async throws -> Int { 0 }
}
