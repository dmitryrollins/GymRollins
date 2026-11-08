import Foundation
import SwiftData

// The server move (docs/specs/2026-11-07-cloudflare-backend-design.md, section 4): when this build talks to another API
// than the one the data last synced with, the local copy goes to the next account that signs in, and every record that
// synced goes up again. Nothing is deleted except Claude's pending proposals, which only the old server could resolve.
extension SyncStore {
    private static let serverKey = "gymrollins.sync.server"

    /// The API this phone's data last synced with (`ApiConfig.origin`); nil until a launch records one.
    public var syncedServer: String? {
        get { defaults.string(forKey: Self.serverKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.serverKey) }
            else { defaults.removeObject(forKey: Self.serverKey) }
        }
    }

    /// Run at launch, before the session is restored, with the API this build talks to. When another server (or none)
    /// is recorded and the data carries an owner, a pull cursor or a server version, the move runs:
    /// - the owner, the cursors and the recorded refusals are forgotten;
    /// - every record that syncs with the account loses its server version and goes dirty, keeping its edit time;
    /// - synced listings forget the old server's photo names, so pictures on this phone upload again;
    /// - pending proposals go, and resolutions not yet sent count as sent.
    /// Then `server` is recorded. The store is saved before anything in `defaults` changes, so a move that fails runs
    /// again at the next launch. Returns whether the move ran.
    @discardableResult
    public func moveToServer(_ server: String) throws -> Bool {
        guard syncedServer != server else { return false }
        let moves = try hasServerState()
        if moves {
            try markEverythingUnsynced()
            for entity in SyncEntity.allCases { clearCursor(for: entity) }
            forgetOwnershipAndFailures()
        }
        syncedServer = server
        return moves
    }

    /// An owner, a pull cursor, or a record holding a server version.
    private func hasServerState() throws -> Bool {
        if ownerUserId != nil || SyncEntity.allCases.contains(where: { cursor(for: $0) != nil }) { return true }
        return try accountRecords().contains { $0.serverUpdatedAt != nil }
    }

    private func markEverythingUnsynced() throws {
        for record in try accountRecords() {
            record.serverUpdatedAt = nil
            record.dirty = true
        }
        let synced = GymVisibility.synced.rawValue
        for listing in try context.fetch(FetchDescriptor<GymListingRecord>(
            predicate: #Predicate { $0.visibilityRaw == synced })) {
            listing.remotePhotoPath = nil
        }
        let pending = ProposalStatus.pending.rawValue
        for proposal in try context.fetch(FetchDescriptor<ProposalRecord>()) {
            if proposal.statusRaw == pending {
                context.delete(proposal)
            } else {
                proposal.dirty = false
                proposal.serverUpdatedAt = nil
            }
        }
        do {
            try context.save()
        } catch {
            context.rollback() // leave no half-moved records in the context for a later save to commit
            throw error
        }
    }

    /// Every record that syncs with the account: the aggregate roots, and the gyms and listings synced to it ("This
    /// phone only" rows and the shared catalogue's are left alone).
    private func accountRecords() throws -> [any SyncTracked] {
        let synced = GymVisibility.synced.rawValue
        var records: [any SyncTracked] = []
        records += try every(ProfileRecord.self)
        records += try every(CustomExerciseRecord.self)
        records += try every(ExercisePreferenceRecord.self)
        records += try every(RoutineRecord.self)
        records += try every(WeekdayRecord.self)
        records += try every(MuscleTargetRecord.self)
        records += try every(BodyweightRecord.self)
        records += try every(WorkoutRecord.self)
        records += try context.fetch(FetchDescriptor<GymRecord>(predicate: #Predicate { $0.visibilityRaw == synced }))
            .map { $0 as any SyncTracked }
        records += try context.fetch(FetchDescriptor<GymListingRecord>(
            predicate: #Predicate { $0.visibilityRaw == synced })).map { $0 as any SyncTracked }
        return records
    }

    private func every<T: PersistentModel & SyncTracked>(_ type: T.Type) throws -> [any SyncTracked] {
        try context.fetch(FetchDescriptor<T>()).map { $0 as any SyncTracked }
    }
}
