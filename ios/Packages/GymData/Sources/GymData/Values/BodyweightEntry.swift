import Foundation

/// Where a weigh-in came from: typed in the app (or by Claude / an import), or read from Apple Health.
public enum BodyweightSource: String, Codable, Sendable, CaseIterable {
    case app
    case appleHealth = "apple_health"
}

public struct BodyweightEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let date: Date
    public let weightKg: Double
    public let bodyFatPct: Double?
    public let timeOfDay: String?
    public let source: BodyweightSource
    /// For weigh-ins read from Apple Health: the body mass sample's UUID (dedupe, deletions) and the body fat
    /// sample's UUID when one supplied `bodyFatPct`.
    public let healthSampleId: UUID?
    public let healthFatSampleId: UUID?

    public init(id: UUID = UUID(), date: Date, weightKg: Double, bodyFatPct: Double? = nil, timeOfDay: String? = nil,
                source: BodyweightSource = .app, healthSampleId: UUID? = nil, healthFatSampleId: UUID? = nil) {
        self.id = id
        self.date = date
        self.weightKg = weightKg
        self.bodyFatPct = bodyFatPct
        self.timeOfDay = timeOfDay
        self.source = source
        self.healthSampleId = healthSampleId
        self.healthFatSampleId = healthFatSampleId
    }

    enum CodingKeys: String, CodingKey {
        case id, date, weightKg, bodyFatPct, timeOfDay, source, healthSampleId, healthFatSampleId
    }

    /// Older payloads (backups, sync rows) have no `source`: they are app entries.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), date: try c.decode(Date.self, forKey: .date),
                  weightKg: try c.decode(Double.self, forKey: .weightKg),
                  bodyFatPct: try c.decodeIfPresent(Double.self, forKey: .bodyFatPct),
                  timeOfDay: try c.decodeIfPresent(String.self, forKey: .timeOfDay),
                  source: try c.decodeIfPresent(BodyweightSource.self, forKey: .source) ?? .app,
                  healthSampleId: try c.decodeIfPresent(UUID.self, forKey: .healthSampleId),
                  healthFatSampleId: try c.decodeIfPresent(UUID.self, forKey: .healthFatSampleId))
    }
}
