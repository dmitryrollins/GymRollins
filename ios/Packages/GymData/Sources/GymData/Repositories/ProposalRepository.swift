import Foundation
import GymCore
import SwiftData
import os

/// Claude's proposals on this device. Remote rows arrive with `upsertRemote` (the server's full pending list);
/// local resolutions (`markApplied`, `dismiss`, `undo`) go dirty until `markSynced`.
@MainActor
public final class ProposalRepository {
    private let context: ModelContext
    private let now: () -> Date
    private static let log = Logger(subsystem: "com.rollins.gymrollins", category: "proposals")

    /// False for a transaction-scoped repository: writes are staged in the context and the caller saves (or
    /// rolls back) once for the whole transaction.
    private let autosave: Bool

    public convenience init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.init(context: context, now: now, autosave: true)
    }

    init(context: ModelContext, now: @escaping () -> Date, autosave: Bool) {
        self.context = context
        self.now = now
        self.autosave = autosave
    }

    private func persist() throws {
        if autosave { try context.save() }
    }

    // MARK: Reading

    /// Pending proposals, newest first.
    public func pending() throws -> [Proposal] {
        let raw = ProposalStatus.pending.rawValue
        let descriptor = FetchDescriptor<ProposalRecord>(predicate: #Predicate { $0.statusRaw == raw },
                                                         sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try context.fetch(descriptor).compactMap(value)
    }

    /// Resolved proposals, most recently resolved first.
    public func recent(limit: Int) throws -> [Proposal] {
        let raw = ProposalStatus.pending.rawValue
        var descriptor = FetchDescriptor<ProposalRecord>(predicate: #Predicate { $0.statusRaw != raw },
                                                         sortBy: [SortDescriptor(\.resolvedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).compactMap(value)
    }

    public func proposal(_ id: UUID) throws -> Proposal? {
        try record(id).flatMap(value)
    }

    func record(_ id: UUID) throws -> ProposalRecord? {
        try context.fetch(FetchDescriptor<ProposalRecord>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: Remote

    /// Stores the server's pending proposals. New ones are inserted clean; a proposal still pending here but no
    /// longer in the server's list was resolved on another device, so it is dropped. Local resolutions are kept.
    public func upsertRemote(_ remote: [Proposal]) throws {
        let ids = Set(remote.map(\.id))
        for p in remote where try record(p.id) == nil {
            let r = ProposalRecord(id: p.id, createdAt: p.createdAt, source: p.source, summary: p.summary,
                                   changesData: try JSONEncoder().encode(p.changes), statusRaw: p.status.rawValue,
                                   now: now())
            context.insert(r)
        }
        let raw = ProposalStatus.pending.rawValue
        let stale = try context.fetch(FetchDescriptor<ProposalRecord>(predicate: #Predicate { $0.statusRaw == raw }))
            .filter { !$0.dirty && !ids.contains($0.id) }
        stale.forEach(context.delete)
        try persist()
    }

    // MARK: Resolving

    /// Records that `changeIds` of the proposal's `total` changes were applied over `snapshot` (the plan before).
    public func markApplied(_ id: UUID, changeIds: [String], total: Int, snapshot: PlanState,
                            skipped: [PlanViolation] = [], auto: Bool = false) throws {
        guard let r = try record(id) else { throw ProposalError.notFound }
        r.statusRaw = (changeIds.count >= total ? ProposalStatus.applied : .partial).rawValue
        r.appliedChangeIds = changeIds
        r.snapshotData = try JSONEncoder().encode(snapshot)
        r.skippedData = skipped.isEmpty ? nil : try JSONEncoder().encode(skipped)
        r.autoApplied = auto
        touchResolved(r)
        try persist()
    }

    public func dismiss(_ id: UUID) throws {
        guard let r = try record(id) else { throw ProposalError.notFound }
        r.statusRaw = ProposalStatus.dismissed.rawValue
        r.appliedChangeIds = []
        r.snapshotData = nil
        touchResolved(r)
        try persist()
    }

    /// Takes back an applied proposal: returns the plan snapshot to restore (nil when there's nothing to undo or
    /// the 7 days are over) and marks the proposal dismissed.
    public func undo(_ id: UUID) throws -> PlanState? {
        guard let r = try record(id), let p = value(r), p.canUndo(at: now()), let data = r.snapshotData else {
            return nil
        }
        let snapshot = try JSONDecoder().decode(PlanState.self, from: data)
        r.statusRaw = ProposalStatus.dismissed.rawValue
        r.appliedChangeIds = []
        r.snapshotData = nil
        touchResolved(r)
        try persist()
        return snapshot
    }

    /// Notes changes that failed validation on a proposal that stays pending (not pushed).
    public func recordSkipped(_ id: UUID, skipped: [PlanViolation]) throws {
        guard let r = try record(id) else { throw ProposalError.notFound }
        r.skippedData = skipped.isEmpty ? nil : try JSONEncoder().encode(skipped)
        try persist()
    }

    private func touchResolved(_ r: ProposalRecord) {
        r.resolvedAt = now()
        r.updatedAt = now()
        r.dirty = true
    }

    // MARK: Sync

    public func dirty() throws -> [ProposalResolution] {
        try context.fetch(FetchDescriptor<ProposalRecord>(predicate: #Predicate { $0.dirty }))
            .compactMap { r in
                guard let status = ProposalStatus(rawValue: r.statusRaw) else { return nil }
                return ProposalResolution(id: r.id, status: status, appliedChangeIds: r.appliedChangeIds,
                                          resolvedAt: max(r.resolvedAt ?? r.updatedAt, r.createdAt),
                                          updatedAt: r.updatedAt)
            }
    }

    /// The resolution pushed with `clientUpdatedAt` reached the server; clean unless edited again since.
    public func markSynced(_ id: UUID, clientUpdatedAt: Date) throws {
        guard let r = try record(id) else { return }
        if r.updatedAt == clientUpdatedAt { r.dirty = false }
        try persist()
    }

    // MARK: Mapping

    private func value(_ r: ProposalRecord) -> Proposal? {
        do {
            let changes = try JSONDecoder().decode([PlanChange].self, from: r.changesData)
            let skipped = try r.skippedData.map { try JSONDecoder().decode([PlanViolation].self, from: $0) } ?? []
            return Proposal(id: r.id, createdAt: r.createdAt, source: r.source, summary: r.summary, changes: changes,
                            status: ProposalStatus(rawValue: r.statusRaw) ?? .pending,
                            appliedChangeIds: r.appliedChangeIds, skipped: skipped, resolvedAt: r.resolvedAt,
                            autoApplied: r.autoApplied, hasSnapshot: r.snapshotData != nil)
        } catch {
            Self.log.error("Unreadable proposal \(r.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
