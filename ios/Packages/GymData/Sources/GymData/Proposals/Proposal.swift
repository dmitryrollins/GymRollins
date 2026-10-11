import Foundation
import GymCore

public enum ProposalStatus: String, Codable, Sendable, CaseIterable {
    case pending, applied, dismissed, partial
}

/// A Claude proposal as the app sees it (also the shape a pull hands to `ProposalRepository.upsertRemote`).
public struct Proposal: Codable, Sendable, Equatable, Identifiable {
    /// How long an applied proposal can be undone.
    public static let undoWindow: TimeInterval = 7 * 86_400

    public let id: UUID
    public let createdAt: Date
    public let source: String
    public let summary: String
    public let changes: [PlanChange]
    public let status: ProposalStatus
    public let appliedChangeIds: [String]
    /// Changes that failed validation when this proposal was (auto-)applied.
    public let skipped: [PlanViolation]
    public let resolvedAt: Date?
    public let autoApplied: Bool
    public let hasSnapshot: Bool

    public init(id: UUID, createdAt: Date, source: String = "claude", summary: String, changes: [PlanChange],
                status: ProposalStatus = .pending, appliedChangeIds: [String] = [], skipped: [PlanViolation] = [],
                resolvedAt: Date? = nil, autoApplied: Bool = false, hasSnapshot: Bool = false) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.summary = summary
        self.changes = changes
        self.status = status
        self.appliedChangeIds = appliedChangeIds
        self.skipped = skipped
        self.resolvedAt = resolvedAt
        self.autoApplied = autoApplied
        self.hasSnapshot = hasSnapshot
    }

    public var proposal: PlanProposal { PlanProposal(summary: summary, changes: changes) }

    /// Applied (fully or partly) with a stored snapshot, less than 7 days ago.
    public func canUndo(at now: Date) -> Bool {
        guard hasSnapshot, status == .applied || status == .partial, let resolvedAt else { return false }
        return now.timeIntervalSince(resolvedAt) < Self.undoWindow
    }
}

/// A local resolution waiting to be pushed (`resolveProposal`).
public struct ProposalResolution: Sendable, Equatable {
    public let id: UUID
    public let status: ProposalStatus
    public let appliedChangeIds: [String]
    /// When it was resolved, never before the proposal was created (the server's last-write-wins guard).
    public let resolvedAt: Date
    /// The local edit time, for `markSynced`.
    public let updatedAt: Date
}

public enum ProposalError: Error, Equatable {
    case notFound
    /// No selected change is valid against the current plan.
    case nothingToApply
    case alreadyResolved
}
