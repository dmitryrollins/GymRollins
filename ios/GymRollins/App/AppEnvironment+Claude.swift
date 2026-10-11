import Foundation
import GymCore
import GymData

// Claude: proposals (review, apply, undo, dismiss, auto-apply) and the MCP permissions.
extension AppEnvironment {
    /// A service over the current library (custom exercises included).
    func proposalService() -> ProposalService {
        let library = self.library
        return ProposalService(context: container.mainContext, exerciseExists: { library.exercise($0) != nil },
                               mode: { library.exercise($0)?.mode ?? .reps }, now: now)
    }

    func pendingProposals() -> [Proposal] {
        do { return try proposals.pending() } catch {
            Self.log.error("Load proposals failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Applies the selected changes; the plan reloads and syncs, `today` changes switch Today for their date, and
    /// Today offers "Undo".
    @discardableResult
    func applyProposal(_ id: UUID, changeIds: Set<String>) throws -> ProposalApplyOutcome {
        let outcome = try proposalService().apply(id, changeIds: changeIds)
        applyDayRoutines(outcome.days)
        setLastApplied((id, outcome.applied.count))
        planChanged()
        return outcome
    }

    func dismissProposal(_ id: UUID) throws {
        try proposalService().dismiss(id)
        planChanged()
    }

    /// Restores the plan from before the proposal was applied. False when it can no longer be undone.
    @discardableResult
    func undoProposal(_ id: UUID) throws -> Bool {
        let applied = try proposals.proposal(id)
        let undone = try proposalService().undo(id)
        if undone, let applied { undoDayRoutines(of: applied) }
        if lastApplied?.id == id { setLastApplied(nil) }
        planChanged()
        return undone
    }

    func clearLastApplied() { setLastApplied(nil) }

    /// Saves Claude's permissions (synced with the profile); turning auto-apply on applies what's pending now.
    func saveMcpPermissions(readWorkouts: Bool, readBody: Bool, readPlan: Bool, propose: Bool,
                            autoApply: Bool) throws {
        try profiles.setMcpPermissions(readWorkouts: readWorkouts, readBody: readBody, readPlan: readPlan,
                                       propose: propose, autoApply: autoApply)
        reloadProfile()
        sync.localDataChanged()
        if autoApply { autoApplyProposals() }
    }

    /// "Disconnect Claude": every permission goes off first and the profile is pushed at once (RLS enforces the
    /// flags for any token Claude still holds), then the connector's OAuth grant is revoked. Revoking deletes its
    /// sessions and refresh tokens, so it can't refresh and the MCP endpoint refuses its access token at once; only
    /// direct PostgREST use of that stateless JWT stays possible until it expires, which the flags-off guard covers.
    /// Returns the grants revoked; succeeds only when the server stored the flags AND the grant was revoked
    /// (`ClaudeDisconnectError` says which step failed; the revoke is not attempted if the flags weren't stored).
    @discardableResult
    func disconnectClaude() async throws -> Int {
        try saveMcpPermissions(readWorkouts: false, readBody: false, readPlan: false, propose: false, autoApply: false)
        do { try await sync.pushProfileNow() } catch {
            Self.log.error("Push Claude permissions failed: \(String(describing: error), privacy: .public)")
            throw ClaudeDisconnectError.permissionsNotSaved
        }
        do { return try await sync.revokeClaudeAccess() } catch {
            Self.log.error("Revoke Claude access failed: \(String(describing: error), privacy: .public)")
            throw ClaudeDisconnectError.accessNotRevoked
        }
    }

    /// Auto-apply after a sync round's pull. The round may have pulled custom exercises the proposals refer to,
    /// and `library` otherwise refreshes only after the round (`onRemoteChanges`), so reload it first.
    func autoApplyPulledProposals() throws -> Int {
        reloadLibrary()
        return try proposalService().autoApplyPending { [weak self] _, outcome in self?.applyDayRoutines(outcome.days) }
    }

    func autoApplyProposals() {
        do {
            let applied = try proposalService().autoApplyPending { [weak self] _, outcome in
                self?.applyDayRoutines(outcome.days)
            }
            if applied > 0 { planChanged() }
        } catch {
            Self.log.error("Auto-apply proposals failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Which step of "Disconnect Claude" failed (the permissions are off on this iPhone either way).
enum ClaudeDisconnectError: Error, Equatable {
    /// The server didn't store the permissions-off profile (offline, refused, or kept a newer edit).
    case permissionsNotSaved
    /// The permissions are off in the account, but the OAuth grant couldn't be revoked.
    case accessNotRevoked

    var message: String {
        switch self {
        case .permissionsNotSaved:
            "Claude's permissions are off on this iPhone but couldn't be saved to your account, so Claude may still "
                + "have access. Check your connection and tap Disconnect Claude again."
        case .accessNotRevoked:
            "Claude's permissions are off, but its access couldn't be revoked. Check your connection and tap "
                + "Disconnect Claude again."
        }
    }
}
