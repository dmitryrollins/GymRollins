import Foundation

/// What an admin decides on. The server never says who wrote it or who reported it.
public struct ModerationEntry: Sendable, Equatable, Identifiable {
    public let targetType: GymTargetType
    public let targetId: UUID
    public let title: String
    public let photoPath: String?
    public let reportCount: Int
    /// Reasons by how many reporters gave each, most given first.
    public let reasons: [ReasonCount]
    public let notes: [String]
    public let status: Status
    /// A gym's address and a listing's own notes: what the target says about itself, to judge the reports by.
    public let address: String?
    public let listingNotes: String?

    public var id: UUID { targetId }

    /// `removed` rows are only here because their photo still has to be deleted.
    public enum Status: String, Sendable { case active, flagged, removed }

    /// Hidden from everyone until an admin decides. A removed row is hidden too, but it is waiting for its photo.
    public var isHidden: Bool { status == .flagged }
    public var photoStillToDelete: Bool { status == .removed }

    public struct ReasonCount: Sendable, Equatable {
        public let reason: String
        public let count: Int

        public init(reason: String, count: Int) {
            self.reason = reason
            self.count = count
        }
    }

    public init(targetType: GymTargetType, targetId: UUID, title: String, photoPath: String?, reportCount: Int,
                reasons: [ReasonCount], notes: [String], status: Status = .active, address: String? = nil,
                listingNotes: String? = nil) {
        self.targetType = targetType
        self.targetId = targetId
        self.title = title
        self.photoPath = photoPath
        self.reportCount = reportCount
        self.reasons = reasons
        self.notes = notes
        self.status = status
        self.address = address
        self.listingNotes = listingNotes
    }
}

public enum ModerationAction: String, Sendable { case restore, remove }
