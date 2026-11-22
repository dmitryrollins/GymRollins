import Foundation
import GymCore
import GymData

/// `workout_measurements` (server/migrations/0014_workout_measurements.sql): what Apple Health measured during one
/// GymRollins workout (plan 40). The key is the account plus the workout's id; the server takes a row only for one
/// of the account's workouts.
public struct WorkoutMeasurementDTO: Codable, Sendable, Equatable, ServerStamped {
    public let workoutId: UUID
    public let recordedBy: MeasurementSnapshot.RecordedBy?
    public let durationS: Double?
    public let activeKcal: Double?
    public let totalKcal: Double?
    public let avgHr: Int?
    public let maxHr: Int?
    public let postHr: Int?
    public let effort: Int?
    public let effortEstimated: Bool
    public let clientUpdatedAt: Date
    public let deletedAt: Date?
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case effort
        case workoutId = "workout_id", recordedBy = "recorded_by", durationS = "duration_s"
        case activeKcal = "active_kcal", totalKcal = "total_kcal", avgHr = "avg_hr", maxHr = "max_hr"
        case postHr = "post_hr", effortEstimated = "effort_estimated"
        case clientUpdatedAt = "client_updated_at", deletedAt = "deleted_at", updatedAt = "updated_at"
    }

    public init(_ row: SyncRow<MeasurementSnapshot>) {
        let m = row.value
        workoutId = m.workoutId
        recordedBy = m.recordedBy
        durationS = m.durationS
        activeKcal = m.activeKcal
        totalKcal = m.totalKcal
        avgHr = m.avgHr
        maxHr = m.maxHr
        postHr = m.postHr
        effort = m.effort
        effortEstimated = m.effortEstimated
        clientUpdatedAt = row.clientUpdatedAt
        deletedAt = row.deletedAt
        updatedAt = row.serverUpdatedAt
    }

    public func toDomain() -> SyncRow<MeasurementSnapshot> {
        SyncRow(value: MeasurementSnapshot(workoutId: workoutId, recordedBy: recordedBy, durationS: durationS,
                                           activeKcal: activeKcal, totalKcal: totalKcal, avgHr: avgHr, maxHr: maxHr,
                                           postHr: postHr, effort: effort, effortEstimated: effortEstimated,
                                           clientUpdatedAt: clientUpdatedAt),
                clientUpdatedAt: clientUpdatedAt, deletedAt: deletedAt, serverUpdatedAt: updatedAt)
    }

    /// Nulls are written explicitly; `updated_at` is server-owned and never sent.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(workoutId, forKey: .workoutId)
        try c.encode(recordedBy, forKey: .recordedBy)
        try c.encode(durationS, forKey: .durationS)
        try c.encode(activeKcal, forKey: .activeKcal)
        try c.encode(totalKcal, forKey: .totalKcal)
        try c.encode(avgHr, forKey: .avgHr)
        try c.encode(maxHr, forKey: .maxHr)
        try c.encode(postHr, forKey: .postHr)
        try c.encode(effort, forKey: .effort)
        try c.encode(effortEstimated, forKey: .effortEstimated)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
    }
}
