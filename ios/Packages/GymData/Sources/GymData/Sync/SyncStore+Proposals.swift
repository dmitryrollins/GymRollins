import Foundation

// Claude's proposals: the server's pending list in, local resolutions out.
extension SyncStore {
    public func applyRemote(proposals: [Proposal]) throws {
        try ProposalRepository(context: context, now: now).upsertRemote(proposals)
    }

    public func dirtyProposals() throws -> [ProposalResolution] {
        try ProposalRepository(context: context, now: now).dirty()
    }

    public func markProposalSynced(_ id: UUID, clientUpdatedAt: Date) throws {
        try ProposalRepository(context: context, now: now).markSynced(id, clientUpdatedAt: clientUpdatedAt)
        clearSyncFailure(.proposals, id: id.uuidString)
    }

    /// Drops proposal failures that no longer apply, so they don't linger in Account forever: a malformed row the
    /// server no longer lists as pending (resolved or deleted elsewhere) or a refused resolution no longer dirty.
    public func pruneProposalFailures(malformedIds: Set<String>) throws {
        let dirty = Set(try dirtyProposals().map(\.id.uuidString))
        for failure in syncFailures() where failure.entity == .proposals
            && !malformedIds.contains(failure.id) && !dirty.contains(failure.id) {
            clearSyncFailure(.proposals, id: failure.id)
        }
    }
}

extension SyncStore {
    public func pendingProposalIds() throws -> Set<UUID> {
        Set(try ProposalRepository(context: context, now: now).pending().map(\.id))
    }
}
