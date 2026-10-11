import Foundation
import GymCore
import GymData

/// `public.custom_exercises`.
public struct CustomExerciseDTO: Codable, Sendable, Equatable, ServerStamped {
    public let id: String
    public let n: String
    public let bp: String
    public let eq: String
    public let tg: String
    public let mode: String
    public let bilateral: Bool
    public let clientUpdatedAt: Date
    public let deletedAt: Date?
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, n, bp, eq, tg, mode, bilateral
        case clientUpdatedAt = "client_updated_at", deletedAt = "deleted_at", updatedAt = "updated_at"
    }

    public init(_ row: SyncRow<Exercise>) {
        let ex = row.value
        id = ex.id
        n = ex.name
        bp = ex.bodyPart
        eq = ex.equipment
        tg = ex.target
        mode = ex.mode.rawValue
        bilateral = ex.bilateral
        clientUpdatedAt = row.clientUpdatedAt
        deletedAt = row.deletedAt
        updatedAt = row.serverUpdatedAt
    }

    public func toDomain() -> SyncRow<Exercise> {
        let ex = Exercise(id: id, name: n, bodyPart: bp, equipment: eq, target: tg, isCustom: true,
                          mode: ExerciseMode(rawValue: mode) ?? .reps, bilateral: bilateral)
        return SyncRow(value: ex, clientUpdatedAt: clientUpdatedAt, deletedAt: deletedAt, serverUpdatedAt: updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(n, forKey: .n)
        try c.encode(bp, forKey: .bp)
        try c.encode(eq, forKey: .eq)
        try c.encode(tg, forKey: .tg)
        try c.encode(mode, forKey: .mode)
        try c.encode(bilateral, forKey: .bilateral)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
    }
}
