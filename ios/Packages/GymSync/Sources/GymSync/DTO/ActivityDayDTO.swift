import Foundation
import GymCore
import GymData

/// `activity_days` (server/migrations/0013_health_activities.sql, primary key `(user_id, day)`): one local day of
/// Apple Health activity (plan 39).
public struct ActivityDayDTO: Codable, Sendable, Equatable, ServerStamped {
    /// `YYYY-MM-DD`.
    public let day: String
    public let steps: Int
    public let moveKcal: Double
    public let exerciseMin: Int
    public let standH: Int?
    public let clientUpdatedAt: Date
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case day, steps
        case moveKcal = "move_kcal", exerciseMin = "exercise_min", standH = "stand_h"
        case clientUpdatedAt = "client_updated_at", updatedAt = "updated_at"
    }

    public init(_ row: SyncRow<ActivityDay>) {
        day = row.value.day
        steps = row.value.steps
        moveKcal = row.value.moveKcal
        exerciseMin = row.value.exerciseMin
        standH = row.value.standH
        clientUpdatedAt = row.clientUpdatedAt
        updatedAt = row.serverUpdatedAt
    }

    public func toDomain() -> SyncRow<ActivityDay> {
        SyncRow(value: ActivityDay(day: day, steps: steps, moveKcal: moveKcal, exerciseMin: exerciseMin,
                                   standH: standH),
                clientUpdatedAt: clientUpdatedAt, serverUpdatedAt: updatedAt)
    }

    /// Nulls are written explicitly; `updated_at` is server-owned and never sent.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(day, forKey: .day)
        try c.encode(steps, forKey: .steps)
        try c.encode(moveKcal, forKey: .moveKcal)
        try c.encode(exerciseMin, forKey: .exerciseMin)
        try c.encode(standH, forKey: .standH)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}
