import Foundation
import SwiftData

// The server move (docs/specs/2026-11-07-cloudflare-backend-design.md, section 4): when this build talks to another API
// than the one the data last synced with, the local copy goes to the next account that signs in, and every record that
// synced goes up again. Nothing of the user's is deleted. What goes: Claude's pending proposals, which only the old
// server could resolve, and the old server's shared catalogue (other people's listings, borrowed pictures, the outbox).
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

    private static let catalogueKey = "gymrollins.catalog.server"

    /// The API the shared catalogue's cache (gym ids, cached listings, borrowed pictures, the outbox) came from; nil
    /// until a launch records one. Separate from `syncedServer`: a phone that recorded the Worker origin under an
    /// earlier build, or one that only browsed the catalogue signed out, still holds the old server's catalogue.
    public var catalogueServer: String? {
        get { defaults.string(forKey: Self.catalogueKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.catalogueKey) }
            else { defaults.removeObject(forKey: Self.catalogueKey) }
        }
    }

    /// Run at launch next to `moveToServer`, whatever the account did. When the catalogue marker differs from `server`,
    /// the old catalogue is forgotten (`forgetOldCatalogue`), the store saved, and then the marker recorded, so a
    /// failed save runs again at the next launch. A fresh install has nothing to forget and just records it. Returns
    /// whether it ran.
    @discardableResult
    public func forgetCatalogueOfOtherServer(_ server: String) throws -> Bool {
        guard catalogueServer != server else { return false }
        do {
            try forgetOldCatalogue()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        catalogueServer = server
        return true
    }

    /// Run at launch, before the session is restored, with the API this build talks to. When another server (or none)
    /// is recorded and the data carries an owner, a pull cursor or a server version, the move runs:
    /// - the owner, the cursors and the recorded refusals are forgotten;
    /// - every record that syncs with the account loses its server version and goes dirty, keeping its edit time;
    /// - synced listings forget the old server's photo names, so pictures on this phone upload again;
    /// - pending proposals go, and resolutions not yet sent count as sent;
    /// - the shared catalogue forgets the old server (`forgetOldCatalogue`).
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
        try forgetOldCatalogue()
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

    /// The shared catalogue's cache names the old server's rows: its gym ids, listings and pictures, and the outbox's
    /// shares, confirmations, reports and blocks (for the old account). None of them is on the new server.
    /// - The user's own shared listings, and those still waiting to be shared, become "This phone only", with their
    ///   photos: they are the user's equipment, and sharing them again is the user's call.
    /// - Other people's cached listings stay until the gym's next refresh, which the cleared stamp makes its next open.
    ///   The new server doesn't know the old gym id, so that refresh drops them and their pictures, as it does when a
    ///   moderator removed a gym; the maps gym keeps the old id until then, because that is how the refresh finds out.
    /// - A flagged or removed own listing becomes active again; an `unsupported` one stays (it has no loads).
    /// - Items lose the catalogue picture they borrowed, and the outbox is emptied.
    private func forgetOldCatalogue() throws {
        let shared = GymVisibility.shared.rawValue
        let uploaded = UploadState.uploaded.rawValue
        let cached = try context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.visibilityRaw == shared }))
        for listing in cached where listing.isOwn || listing.uploadStateRaw != uploaded {
            listing.visibilityRaw = GymVisibility.device.rawValue
            listing.uploadStateRaw = UploadState.local.rawValue
            listing.uploadError = nil
            listing.duplicatesData = nil
            listing.remoteId = nil
            listing.remotePhotoPath = nil
            if listing.statusRaw != ListingStatus.unsupported.rawValue { // `unsupported` loads are `{}`; stay that way
                listing.statusRaw = ListingStatus.active.rawValue
            }
            listing.confirmCount = 0
            listing.confirmedByMe = false
        }
        for gym in try context.fetch(FetchDescriptor<GymRecord>()) where gym.mapsPlaceId != nil {
            gym.catalogRefreshedAt = nil
        }
        for item in try context.fetch(FetchDescriptor<EquipmentItemRecord>()) where item.catalogPhotoPath != nil {
            item.catalogPhotoPath = nil
            item.catalogPhotoListingId = nil
        }
        for row in try context.fetch(FetchDescriptor<ShareOutboxRecord>()) { context.delete(row) }
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
