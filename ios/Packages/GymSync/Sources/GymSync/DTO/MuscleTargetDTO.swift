import Foundation
import GymCore
import GymData

/// `public.muscle_targets` (primary key `(user_id, muscle)`): one muscle group's weekly hard-set target.
public struct MuscleTargetDTO: Codable, Sendable, Equatable, ServerStamped {
    public let muscle: String
    public let minSets: Int
    public let maxSets: Int
    public let clientUpdatedAt: Date
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case muscle
        case minSets = "min_sets", maxSets = "max_sets"
        case clientUpdatedAt = "client_updated_at", updatedAt = "updated_at"
    }

    public init(_ row: SyncRow<MuscleTargetValue>) {
        muscle = row.value.group.rawValue
        minSets = row.value.range.min
        maxSets = row.value.range.max
        clientUpdatedAt = row.clientUpdatedAt
        updatedAt = row.serverUpdatedAt
    }

    /// nil for a muscle id this app version doesn't know (skipped, like an unknown weekday).
    public func toDomain() -> SyncRow<MuscleTargetValue>? {
        guard let group = MuscleGroup(rawValue: muscle) else { return nil }
        return SyncRow(value: MuscleTargetValue(group: group, range: SetTargetRange(min: minSets, max: maxSets)),
                       clientUpdatedAt: clientUpdatedAt, serverUpdatedAt: updatedAt)
    }

    /// `updated_at` is server-owned and never sent.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(muscle, forKey: .muscle)
        try c.encode(minSets, forKey: .minSets)
        try c.encode(maxSets, forKey: .maxSets)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}
