import Foundation
import GymCore
import GymData

/// `health_activities` (server/migrations/0013_health_activities.sql): an outside workout read from Apple Health
/// (plan 39). The key is the account plus the HealthKit workout's UUID.
public struct HealthActivityDTO: Codable, Sendable, Equatable, ServerStamped {
    public let id: UUID
    public let kind: String
    public let startedAt: Date
    public let endedAt: Date
    public let durationS: Double
    public let kcal: Double?
    public let distanceM: Double?
    public let avgHr: Int?
    public let maxHr: Int?
    public let sourceName: String
    public let fromWatch: Bool
    public let clientUpdatedAt: Date
    public let deletedAt: Date?
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, kind, kcal
        case startedAt = "started_at", endedAt = "ended_at", durationS = "duration_s", distanceM = "distance_m"
        case avgHr = "avg_hr", maxHr = "max_hr", sourceName = "source_name", fromWatch = "from_watch"
        case clientUpdatedAt = "client_updated_at", deletedAt = "deleted_at", updatedAt = "updated_at"
    }

    public init(_ row: SyncRow<HealthActivity>) {
        let a = row.value
        id = a.id
        kind = a.kind
        startedAt = a.startedAt
        endedAt = a.endedAt
        durationS = a.durationS
        kcal = a.kcal
        distanceM = a.distanceM
        avgHr = a.avgHr
        maxHr = a.maxHr
        sourceName = a.sourceName
        fromWatch = a.fromWatch
        clientUpdatedAt = row.clientUpdatedAt
        deletedAt = row.deletedAt
        updatedAt = row.serverUpdatedAt
    }

    public func toDomain() -> SyncRow<HealthActivity> {
        SyncRow(value: HealthActivity(id: id, kind: kind, startedAt: startedAt, endedAt: endedAt, durationS: durationS,
                                      kcal: kcal, distanceM: distanceM, avgHr: avgHr, maxHr: maxHr,
                                      sourceName: sourceName, fromWatch: fromWatch),
                clientUpdatedAt: clientUpdatedAt, deletedAt: deletedAt, serverUpdatedAt: updatedAt)
    }

    /// Nulls are written explicitly; `updated_at` is server-owned and never sent.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt)
        try c.encode(durationS, forKey: .durationS)
        try c.encode(kcal, forKey: .kcal)
        try c.encode(distanceM, forKey: .distanceM)
        try c.encode(avgHr, forKey: .avgHr)
        try c.encode(maxHr, forKey: .maxHr)
        try c.encode(sourceName, forKey: .sourceName)
        try c.encode(fromWatch, forKey: .fromWatch)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
    }
}
