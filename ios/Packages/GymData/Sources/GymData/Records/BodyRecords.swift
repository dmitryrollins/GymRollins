import Foundation
import SwiftData

@Model
public final class BodyweightRecord {
    @Attribute(.unique) public var id: UUID
    public var date: Date
    public var weightKg: Double
    public var bodyFatPct: Double?
    public var timeOfDay: String?
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool
    public var deletedAt: Date?
    /// `BodyweightSource` raw value; nil for rows written before plan 15 (= app).
    public var sourceRaw: String?
    /// Apple Health sample ids (see `BodyweightEntry.healthSampleId`).
    public var healthSampleId: UUID?
    public var healthFatSampleId: UUID?

    public init(id: UUID, date: Date, weightKg: Double, bodyFatPct: Double?, timeOfDay: String?, now: Date,
                source: BodyweightSource = .app) {
        self.id = id
        self.date = date
        self.weightKg = weightKg
        self.bodyFatPct = bodyFatPct
        self.timeOfDay = timeOfDay
        self.updatedAt = now
        self.dirty = true
        self.sourceRaw = source == .app ? nil : source.rawValue
    }

    public var source: BodyweightSource {
        get { sourceRaw.flatMap(BodyweightSource.init(rawValue:)) ?? .app }
        set { sourceRaw = newValue == .app ? nil : newValue.rawValue }
    }
}
