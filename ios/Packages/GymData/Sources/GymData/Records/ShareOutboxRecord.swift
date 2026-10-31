import Foundation
import SwiftData

/// One thing the phone still has to tell the server: share a listing, or confirm someone else's.
@Model
public final class ShareOutboxRecord {
    @Attribute(.unique) public var id: UUID
    public var kindRaw: String
    /// The local listing id.
    public var targetId: UUID
    /// The user who queued it. Only that user's session sends it.
    public var ownerId: UUID
    public var forceNew: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: Kind, targetId: UUID, ownerId: UUID, forceNew: Bool = false, now: Date) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.targetId = targetId
        self.ownerId = ownerId
        self.forceNew = forceNew
        self.createdAt = now
    }

    /// Plan 22 adds `report` and `block`.
    public enum Kind: String, Sendable { case share, confirm }
}
