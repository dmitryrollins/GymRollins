import Foundation
import SwiftData

/// One thing the phone still has to tell the server: share a listing, confirm someone else's, or report or block.
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
    /// Reports and blocks only: what `targetId` names (`GymTargetType`), the reason and the note. For these rows
    /// `targetId` is the server's id, not a local one.
    public var targetTypeRaw: String?
    public var reasonRaw: String?
    public var note: String?
    /// The phone hides the listing `targetId` names until this is sent.
    public var hidesListing: Bool = false
    /// A report of a catalogue photo: `targetId` is the listing the picture came from, which stays visible.
    public var aboutPhoto: Bool = false

    // swiftlint:disable:next function_parameter_count
    public init(id: UUID = UUID(), kind: Kind, targetId: UUID, ownerId: UUID, forceNew: Bool = false,
                targetType: GymTargetType? = nil, reason: ReportReason? = nil, note: String? = nil,
                hidesListing: Bool = false, aboutPhoto: Bool = false, now: Date) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.targetId = targetId
        self.ownerId = ownerId
        self.forceNew = forceNew
        self.createdAt = now
        self.targetTypeRaw = targetType?.rawValue
        self.reasonRaw = reason?.rawValue
        self.note = note
        self.hidesListing = hidesListing
        self.aboutPhoto = aboutPhoto
    }

    public enum Kind: String, Sendable { case share, confirm, report, block }
}
