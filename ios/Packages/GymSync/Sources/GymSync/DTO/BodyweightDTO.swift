import Foundation
import GymData

/// `public.bodyweight`.
public struct BodyweightDTO: Codable, Sendable, Equatable, ServerStamped {
    public let id: UUID
    public let measuredAt: Date
    public let wKg: Double
    public let bfPct: Double?
    public let t: String?
    /// `apple_health` for weigh-ins read from Apple Health; nil (or absent, on older rows) for app entries.
    public let source: String?
    public let healthSampleId: UUID?
    public let healthFatSampleId: UUID?
    public let clientUpdatedAt: Date
    public let deletedAt: Date?
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, t, source
        case healthSampleId = "health_sample_id", healthFatSampleId = "health_fat_sample_id"
        case measuredAt = "measured_at", wKg = "w_kg", bfPct = "bf_pct"
        case clientUpdatedAt = "client_updated_at", deletedAt = "deleted_at", updatedAt = "updated_at"
    }

    public init(_ row: SyncRow<BodyweightEntry>) {
        id = row.value.id
        measuredAt = row.value.date
        wKg = row.value.weightKg
        bfPct = row.value.bodyFatPct
        t = row.value.timeOfDay
        source = row.value.source == .app ? nil : row.value.source.rawValue
        healthSampleId = row.value.healthSampleId
        healthFatSampleId = row.value.healthFatSampleId
        clientUpdatedAt = row.clientUpdatedAt
        deletedAt = row.deletedAt
        updatedAt = row.serverUpdatedAt
    }

    public func toDomain() -> SyncRow<BodyweightEntry> {
        SyncRow(value: BodyweightEntry(id: id, date: measuredAt, weightKg: wKg, bodyFatPct: bfPct, timeOfDay: t,
                                       source: source.flatMap(BodyweightSource.init(rawValue:)) ?? .app,
                                       healthSampleId: healthSampleId, healthFatSampleId: healthFatSampleId),
                clientUpdatedAt: clientUpdatedAt, deletedAt: deletedAt, serverUpdatedAt: updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(measuredAt, forKey: .measuredAt)
        try c.encode(wKg, forKey: .wKg)
        try c.encode(bfPct, forKey: .bfPct)
        try c.encode(t, forKey: .t)
        try c.encode(source, forKey: .source)
        try c.encode(healthSampleId, forKey: .healthSampleId)
        try c.encode(healthFatSampleId, forKey: .healthFatSampleId)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
    }
}
