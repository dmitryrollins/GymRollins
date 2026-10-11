import Foundation
import GymData
import Observation

public enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case offline
    case error(String)
    /// Workouts edited both here and elsewhere; the owner picks "Keep this iPhone's" or "Keep other".
    case conflicts([UUID])
}

/// Offline-first sync: pushes dirty rows (profile, custom exercises, exercise preferences, routines, weekdays, weekly
/// targets, bodyweight, then workouts
/// one RPC each) and proposal resolutions, then pulls each entity since its cursor and applies it through `SyncStore`. Only one sync (or
/// conflict resolution) runs at a time; network failures leave local data untouched and report `.offline`. A row the
/// server refuses for its values is recorded as a `SyncFailure` and skipped, so it can't block the rest of the round.
/// After the pull, pending proposals are auto-applied when the owner allows it (`autoApply`) and pushed at once.
/// `shutdown()` (sign-out, account switch/deletion) stops the engine: after it, no response can reach the store.
@MainActor @Observable
public final class SyncEngine {
    public private(set) var status: SyncStatus = .idle
    public private(set) var lastSyncedAt: Date?
    /// Bumps whenever a pull or a "Keep other" resolution wrote remote rows into the local store, so the app
    /// knows to reload what it shows.
    public private(set) var remoteChangeCount = 0

    @ObservationIgnored let store: SyncStore
    @ObservationIgnored let transport: any SyncTransport
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var running = false
    @ObservationIgnored private var round: Task<Void, Never>?
    /// Set by `shutdown()`; checked after every network await, before anything is written locally.
    @ObservationIgnored public private(set) var isShutDown = false
    @ObservationIgnored private var conflicts: Set<UUID> = []
    /// Runs after each pull (e.g. `ProposalService.autoApplyPending`); returns how many proposals it applied.
    @ObservationIgnored let autoApply: (@MainActor () throws -> Int)?

    public init(store: SyncStore, transport: any SyncTransport, now: @escaping () -> Date = Date.init,
                autoApply: (@MainActor () throws -> Int)? = nil) {
        self.store = store
        self.transport = transport
        self.now = now
        self.autoApply = autoApply
    }

    /// Runs one push + pull round. A call made while another round is running returns immediately.
    public func sync() async {
        await exclusive { await self.runSync() }
    }

    /// Resolves a workout conflict: keeping local re-stamps it with the current time and force-pushes it; keeping the
    /// other version fetches it from the server and replaces the local workout.
    public func resolve(conflict id: UUID, keepLocal: Bool) async {
        await exclusive { await self.runResolve(conflict: id, keepLocal: keepLocal) }
    }

    /// Pushes the profile now, outside the debounce (e.g. Disconnect Claude turning every permission off), after
    /// any running round. Returns once the server stored it (or nothing was waiting); throws when it did not: the
    /// network failed, the server refused the values, or it kept a newer edit (`ProfilePushError.notStored`).
    public func pushProfileNow() async throws {
        var outcome: Result<Void, Error>?
        while outcome == nil {
            if let running = round { await running.value }
            if isShutDown { throw CancellationError() }
            await exclusive {
                do { outcome = .success(try await self.pushProfileStrictly()) } catch { outcome = .failure(error) }
            }
        }
        try outcome?.get()
    }

    /// Stops the engine for good: cancels the running round and waits for it to finish. Responses that arrive
    /// afterwards are dropped, so the caller may wipe the store as soon as this returns.
    public func shutdown() async {
        isShutDown = true
        round?.cancel()
        await round?.value
    }

    /// Throws once the engine is shut down (or its round cancelled). Called after every network await, before
    /// touching the store.
    func ensureLive() throws {
        if isShutDown || Task.isCancelled { throw CancellationError() }
    }

    private func exclusive(_ work: @escaping @MainActor () async -> Void) async {
        guard !running, !isShutDown else { return }
        running = true
        let task = Task { await work() }
        round = task
        await task.value
        round = nil
        running = false
    }

    private func runSync() async {
        status = .syncing
        do {
            var found = try await pushAll()
            found.formUnion(try await pullAll())
            if let autoApply, try autoApply() > 0 {
                // Auto-applied proposals changed routines and resolved proposals: push them in this round.
                noteRemoteChanges()
                found.formUnion(try await pushAll())
            }
            conflicts = found
            lastSyncedAt = now()
            status = settledStatus
        } catch {
            settle(after: error)
        }
    }

    private func runResolve(conflict id: UUID, keepLocal: Bool) async {
        do {
            if keepLocal {
                try store.resolveWorkoutConflict(id: id, keepLocal: true, remote: nil)
                let stale = try await pushWorkouts(only: id, force: true)
                if stale.isEmpty { conflicts.remove(id) }
            } else {
                let remote = try await transport.fetchWorkout(id: id)
                try ensureLive()
                try store.resolveWorkoutConflict(id: id, keepLocal: false, remote: remote?.toDomain())
                conflicts.remove(id)
                noteRemoteChanges()
            }
            status = settledStatus
        } catch {
            settle(after: error)
        }
    }

    /// A stopped engine keeps its last status (nobody shows it any more); anything else maps to offline/error.
    private func settle(after error: Error) {
        guard !isShutDown, !(error is CancellationError) else { return }
        status = Self.status(for: error)
    }

    /// The other device's version of a conflicting workout (for the side-by-side review), or nil if absent.
    public func remoteWorkout(id: UUID) async throws -> WorkoutSnapshot? {
        try await transport.fetchWorkout(id: id)?.toDomain().value
    }

    /// When Claude last used the MCP server for this account (nil if never).
    public func lastMcpUse() async throws -> Date? {
        try await transport.lastMcpUse()
    }

    /// Revokes the OAuth grants this account gave (Claude's connector); returns how many.
    public func revokeOAuthGrants() async throws -> Int {
        try await transport.revokeOAuthGrants()
    }

    func noteRemoteChanges() { remoteChangeCount += 1 }

    private var settledStatus: SyncStatus {
        conflicts.isEmpty ? .idle : .conflicts(conflicts.sorted { $0.uuidString < $1.uuidString })
    }

    private func pushProfileStrictly() async throws {
        let id = SyncStore.profileSyncID
        guard let row = try store.dirtyProfile() else { return }
        let ack: RowAck?
        do {
            ack = try await transport.push(profile: ProfileDTO(row))
            try ensureLive()
        } catch let rejected as SyncRecordRejected {
            try ensureLive()
            store.recordSyncFailure(SyncFailure(entity: .profile, id: id, clientUpdatedAt: row.clientUpdatedAt,
                                                message: rejected.message))
            throw rejected
        }
        guard let ack else { throw ProfilePushError.notStored }
        try store.markSynced(.profile, id: id, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: ack.updatedAt)
    }

    static func status(for error: Error) -> SyncStatus {
        if error is URLError || (error as NSError).domain == NSURLErrorDomain { return .offline }
        return .error("Couldn't sync. Your data is safe on this iPhone; we'll try again later.")
    }
}

/// The server kept a newer profile edit instead of the one pushed.
public enum ProfilePushError: Error, Equatable {
    case notStored
}
