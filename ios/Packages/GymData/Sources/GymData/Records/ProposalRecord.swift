import Foundation
import SwiftData

/// A plan change proposal from Claude, pulled from `public.proposals`. Resolved on the device (applied, partly
/// applied, dismissed); the resolution is pushed back (`dirty`). `snapshotData` is the plan before applying (an
/// encoded `PlanState`), kept for undo; `skippedData` lists the changes that failed validation (`[PlanViolation]`).
@Model
public final class ProposalRecord {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    public var source: String
    public var summary: String
    public var changesData: Data
    public var statusRaw: String
    public var appliedChangeIds: [String]
    public var skippedData: Data?
    public var snapshotData: Data?
    public var autoApplied: Bool
    public var resolvedAt: Date?
    // sync
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool

    public init(id: UUID, createdAt: Date, source: String, summary: String, changesData: Data, statusRaw: String,
                now: Date) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.summary = summary
        self.changesData = changesData
        self.statusRaw = statusRaw
        self.appliedChangeIds = []
        self.autoApplied = false
        self.updatedAt = now
        self.dirty = false
    }
}
