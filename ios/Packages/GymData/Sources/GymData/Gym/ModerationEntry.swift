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

    public var id: UUID { targetId }

    public struct ReasonCount: Sendable, Equatable {
        public let reason: String
        public let count: Int

        public init(reason: String, count: Int) {
            self.reason = reason
            self.count = count
        }
    }

    public init(targetType: GymTargetType, targetId: UUID, title: String, photoPath: String?, reportCount: Int,
                reasons: [ReasonCount], notes: [String]) {
        self.targetType = targetType
        self.targetId = targetId
        self.title = title
        self.photoPath = photoPath
        self.reportCount = reportCount
        self.reasons = reasons
        self.notes = notes
    }
}

public enum ModerationAction: String, Sendable { case restore, remove }
