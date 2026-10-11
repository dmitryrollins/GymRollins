import Foundation
import GymCore
import GymData

/// `public.exercise_prefs` (primary key `(user_id, exercise_id)`; `user_id` defaults to `auth.uid()`).
public struct ExercisePrefDTO: Codable, Sendable, Equatable, ServerStamped {
    public let exerciseId: String
    public let pref: String
    public let clientUpdatedAt: Date
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case pref
        case exerciseId = "exercise_id", clientUpdatedAt = "client_updated_at", updatedAt = "updated_at"
    }

    public init(_ row: SyncRow<ExercisePreferenceSetting>) {
        exerciseId = row.value.exerciseId
        pref = row.value.preference.rawValue
        clientUpdatedAt = row.clientUpdatedAt
        updatedAt = row.serverUpdatedAt
    }

    /// A value this app version doesn't know reads as `normal`.
    public func toDomain() -> SyncRow<ExercisePreferenceSetting> {
        SyncRow(value: ExercisePreferenceSetting(exerciseId: exerciseId, preference: ExercisePreference(storedValue: pref)),
                clientUpdatedAt: clientUpdatedAt, serverUpdatedAt: updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(exerciseId, forKey: .exerciseId)
        try c.encode(pref, forKey: .pref)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}
