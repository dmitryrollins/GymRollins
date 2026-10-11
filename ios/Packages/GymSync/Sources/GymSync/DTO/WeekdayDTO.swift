import Foundation
import GymData

/// `public.week_schedule` (primary key `(user_id, weekday)`; `routine_id` null = rest day).
public struct WeekdayDTO: Codable, Sendable, Equatable, ServerStamped {
    public let weekday: Int
    public let routineId: UUID?
    public let clientUpdatedAt: Date
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case weekday
        case routineId = "routine_id", clientUpdatedAt = "client_updated_at", updatedAt = "updated_at"
    }

    public init(_ row: SyncRow<WeekdayAssignment>) {
        weekday = row.value.weekday
        routineId = row.value.routineId
        clientUpdatedAt = row.clientUpdatedAt
        updatedAt = row.serverUpdatedAt
    }

    public func toDomain() -> SyncRow<WeekdayAssignment> {
        SyncRow(value: WeekdayAssignment(weekday: weekday, routineId: routineId), clientUpdatedAt: clientUpdatedAt,
                serverUpdatedAt: updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(weekday, forKey: .weekday)
        try c.encode(routineId, forKey: .routineId)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}
