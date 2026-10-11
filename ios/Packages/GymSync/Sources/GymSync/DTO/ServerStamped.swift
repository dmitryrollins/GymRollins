import Foundation

/// A pulled row carrying the server's `updated_at`, which drives the per-entity pull cursor.
public protocol ServerStamped: Sendable {
    var updatedAt: Date? { get }
}

/// A pushed row the server accepted: its key and the server's new `updated_at`.
public struct RowAck: Sendable, Equatable {
    public let id: String
    public let updatedAt: Date

    public init(id: String, updatedAt: Date) {
        self.id = id
        self.updatedAt = updatedAt
    }
}

/// `upsert_workout` result: `ok` stored the payload; `stale` means the server holds a newer edit.
public enum WorkoutPushResult: Sendable, Equatable, Decodable {
    case ok(updatedAt: Date)
    case stale(updatedAt: Date)

    enum CodingKeys: String, CodingKey { case status, updatedAt = "updated_at" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        switch try c.decode(String.self, forKey: .status) {
        case "ok": self = .ok(updatedAt: updatedAt)
        case "stale": self = .stale(updatedAt: updatedAt)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .status, in: c, debugDescription: "Unknown status \(other)")
        }
    }
}
