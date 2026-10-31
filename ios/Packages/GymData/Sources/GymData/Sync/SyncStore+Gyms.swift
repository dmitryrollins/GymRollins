import Foundation
import GymCore
import SwiftData

// Private gyms and listings (visibility `synced`). Rows that are `device` or `shared` never appear here: the first
// stay on the phone, the second travel through the share outbox.
extension SyncStore {
    private static var synced: String { GymVisibility.synced.rawValue }

    // MARK: Push

    public func dirtyGyms() throws -> [SyncRow<SyncedGym>] {
        let synced = Self.synced
        return try context.fetch(FetchDescriptor<GymRecord>(
            predicate: #Predicate { $0.dirty && $0.visibilityRaw == synced }, sortBy: [SortDescriptor(\.createdAt)]))
            .map { SyncRow(value: SyncedGym(id: $0.id, name: $0.name, address: $0.address, latitude: $0.latitude,
                                            longitude: $0.longitude),
                           clientUpdatedAt: $0.updatedAt, deletedAt: $0.deletedAt, serverUpdatedAt: $0.serverUpdatedAt) }
    }

    public func dirtyGymListings() throws -> [SyncRow<SyncedListing>] {
        let synced = Self.synced
        let unsupported = ListingStatus.unsupported.rawValue
        let rows = try context.fetch(FetchDescriptor<GymListingRecord>(
            predicate: #Predicate { $0.dirty && $0.visibilityRaw == synced }, sortBy: [SortDescriptor(\.createdAt)]))
        // A row whose loads this version can't read is not sent back: its fields would overwrite newer loads on the
        // server. Deleting it is still sent.
        return try rows.filter { $0.statusRaw != unsupported || $0.deletedAt != nil }.map { r in
            let item = try itemRecord(r.itemId)
            let loads: ListingLoads? = r.statusRaw == unsupported
                ? nil : ((try? JSONDecoder().decode(ListingLoads.self, from: r.loadsData)) ?? ListingLoads.none)
            let value = SyncedListing(id: r.id, gymId: r.gymId, kindId: r.kindId, brand: item?.brand,
                                      model: item?.model, loads: loads, quantity: r.quantity, notes: r.notes,
                                      photoFile: r.photoFile, remotePhotoPath: r.remotePhotoPath)
            return SyncRow(value: value, clientUpdatedAt: r.updatedAt, deletedAt: r.deletedAt,
                           serverUpdatedAt: r.serverUpdatedAt)
        }
    }

    /// A listing the server refused only because its gym was refused stays blocked until it is edited, though the
    /// gym is fine now. Called once the gym is acknowledged, so the listings are tried again.
    public func unblockListings(ofGym gymId: UUID) throws {
        let id = gymId
        for row in try context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.gymId == id })) {
            clearSyncFailure(.gymListings, id: row.id.uuidString)
        }
    }

    /// Remembers the private-bucket name as soon as the upload succeeded, so a retry skips the upload.
    public func setRemotePhotoPath(listingId: UUID, path: String?) throws {
        guard let record = try anyListingRecord(listingId) else { return }
        record.remotePhotoPath = path
        try context.save()
    }

    /// Account deletion has detached the user's photos on the server: the user's own synced listings that still have a
    /// picture file on this phone forget the removed object's name and wait to be pushed, so the next sync uploads the
    /// picture again under a new name.
    public func forgetRemotePhotos() throws {
        let synced = Self.synced
        let rows = try context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate {
            $0.visibilityRaw == synced && $0.deletedAt == nil && $0.photoFile != nil && $0.remotePhotoPath != nil
        }))
        for row in rows {
            row.remotePhotoPath = nil
            row.updatedAt = now()
            row.dirty = true
        }
        try context.save()
    }

    // MARK: Pull

    /// Applies pulled gyms; returns the photo files of listings that went with a removed gym.
    @discardableResult
    public func applyRemote(gyms rows: [SyncRow<SyncedGym>]) throws -> [String] {
        var files: [String] = []
        for row in rows {
            let value = row.value
            let existing = try anyGymRecord(value.id)
            if let existing, !mayApply(row.clientUpdatedAt, to: existing, visibility: existing.visibilityRaw) { continue }
            if row.deletedAt != nil {
                if let existing { files += try removeSyncedGym(existing) }
                continue
            }
            let r = existing ?? {
                let new = GymRecord(id: value.id, name: value.name, address: value.address, now: row.clientUpdatedAt)
                new.visibilityRaw = Self.synced
                context.insert(new)
                return new
            }()
            r.name = value.name
            r.address = value.address
            r.latitude = value.latitude
            r.longitude = value.longitude
            r.deletedAt = nil
            markClean(r, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: row.serverUpdatedAt)
        }
        try context.save()
        return files
    }

    /// Applies pulled listings; returns the local photo files of rows that were removed or whose picture changed.
    @discardableResult
    public func applyRemote(gymListings rows: [SyncRow<SyncedListing>]) throws -> [String] {
        var files: [String] = []
        let repository = GymRepository(context: context, now: now)
        for row in rows {
            let value = row.value
            let existing = try anyListingRecord(value.id)
            if let existing, !mayApply(row.clientUpdatedAt, to: existing, visibility: existing.visibilityRaw) { continue }
            if row.deletedAt != nil {
                if let existing {
                    existing.photoFile.map { files.append($0) }
                    context.delete(existing)
                }
                continue
            }
            guard let gym = try anyGymRecord(value.gymId), gym.visibilityRaw == Self.synced else { continue }
            let item = try repository.itemRecord(kindId: value.kindId, brand: value.brand, model: value.model)
            let r = existing ?? {
                let new = GymListingRecord(id: value.id, gymId: value.gymId, itemId: item.id, kindId: value.kindId,
                                           loadsData: Data(), quantity: value.quantity, notes: value.notes,
                                           photoFile: nil, now: row.clientUpdatedAt)
                new.visibilityRaw = Self.synced
                context.insert(new)
                return new
            }()
            r.gymId = value.gymId
            r.itemId = item.id
            r.kindId = value.kindId
            r.loadsData = value.loads.flatMap { try? JSONEncoder().encode($0) } ?? Data("{}".utf8)
            r.statusRaw = (value.loads == nil ? ListingStatus.unsupported : ListingStatus.active).rawValue
            r.quantity = value.quantity
            r.notes = value.notes
            if r.remotePhotoPath != value.remotePhotoPath {
                r.photoFile.map { files.append($0) }
                r.photoFile = nil
            }
            // A picture only this phone has still has to reach the server, though the rest of the row lost.
            let photoStillToUpload = existing?.dirty == true && r.photoFile != nil && value.remotePhotoPath == nil
            r.remotePhotoPath = value.remotePhotoPath
            r.deletedAt = nil
            markClean(r, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: row.serverUpdatedAt)
            if photoStillToUpload { r.dirty = true }
        }
        try context.save()
        return files
    }

    /// Synced listings whose picture is on the server but not on this phone yet: new ones, and ones whose last
    /// download failed.
    public func listingsMissingPhoto() throws -> [PhotoFetch] {
        let synced = Self.synced
        return try context.fetch(FetchDescriptor<GymListingRecord>(
            predicate: #Predicate { $0.visibilityRaw == synced && $0.deletedAt == nil && $0.photoFile == nil },
            sortBy: [SortDescriptor(\.createdAt)]))
            .compactMap { row in row.remotePhotoPath.map { PhotoFetch(listingId: row.id, path: $0) } }
    }

    /// Attaches a downloaded picture. Not an edit: nothing goes dirty. False when the listing is gone or already has a
    /// picture (the user attached one while this downloaded): the caller deletes the file it just saved.
    @discardableResult
    public func setPhotoFile(listingId: UUID, file: String) throws -> Bool {
        guard let record = try anyListingRecord(listingId), record.photoFile == nil else { return false }
        record.photoFile = file
        try context.save()
        return true
    }

    // MARK: Internals

    func anyGymRecord(_ id: UUID) throws -> GymRecord? {
        try context.fetch(FetchDescriptor<GymRecord>(predicate: #Predicate { $0.id == id })).first
    }

    func anyListingRecord(_ id: UUID) throws -> GymListingRecord? {
        try context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func itemRecord(_ id: UUID) throws -> EquipmentItemRecord? {
        try context.fetch(FetchDescriptor<EquipmentItemRecord>(predicate: #Predicate { $0.id == id })).first
    }

    /// Remote rows only ever replace synced rows, and dirty ones only when the remote edit is newer.
    private func mayApply(_ remoteEdit: Date, to record: any SyncTracked, visibility: String) -> Bool {
        visibility == Self.synced && remoteWins(over: record, remoteEdit: remoteEdit)
    }

    /// Called by `markSynced`: a deletion the server has now stored needs no row any more.
    func dropAcknowledgedTombstone(_ record: any SyncTracked) {
        if let gym = record as? GymRecord, gym.deletedAt != nil, !gym.dirty { context.delete(gym) }
        if let listing = record as? GymListingRecord, listing.deletedAt != nil, !listing.dirty {
            context.delete(listing)
        }
    }

    func hasSyncedGymData() throws -> Bool {
        let synced = Self.synced
        return try context.fetchCount(FetchDescriptor<GymRecord>(predicate: #Predicate { $0.visibilityRaw == synced })) > 0
            || context.fetchCount(FetchDescriptor<GymListingRecord>(
                predicate: #Predicate { $0.visibilityRaw == synced })) > 0
    }

    /// A gym deleted elsewhere: its synced listings go; if listings that only exist here remain, the gym stays as a
    /// "This phone only" gym so they keep a home.
    private func removeSyncedGym(_ gym: GymRecord) throws -> [String] {
        let id = gym.id
        var files: [String] = []
        var kept = false
        for row in try context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.gymId == id })) {
            if row.visibilityRaw == Self.synced {
                row.photoFile.map { files.append($0) }
                context.delete(row)
            } else {
                kept = true
            }
        }
        if kept {
            // The old id names a deleted server row, which must never be written to again: the gym that stays gets
            // an id of its own, and the app is told so it can move its pointer.
            demote(gym, owner: nil)
            let newId = UUID()
            try moveGym(gym, to: newId)
            recordGymMove(from: id, to: newId)
        } else {
            context.delete(gym)
        }
        return files
    }

    // MARK: Sign-out

    /// Decision 9. Keeps everything only this phone has; removes what the server holds (synced rows that reached it,
    /// cached shared listings) and returns those photo files. Never loses an edit: a synced row that hasn't been
    /// pushed, and a share that hasn't happened, become "This phone only" rows.
    func resetGymData() throws -> [String] {
        var files: [String] = []
        let owner = ownerUserId
        for row in try context.fetch(FetchDescriptor<ShareOutboxRecord>()) {
            if row.kindRaw == ShareOutboxRecord.Kind.share.rawValue,
               let listing = try anyListingRecord(row.targetId) { demote(listing, owner: row.ownerId) }
            context.delete(row)
        }
        for listing in try context.fetch(FetchDescriptor<GymListingRecord>()) {
            files += resetListing(listing, owner: owner)
        }
        // Which pictures were reported belongs to the account that reported them.
        for item in try context.fetch(FetchDescriptor<EquipmentItemRecord>()) { item.reportedPhotoListingId = nil }
        let remaining = Set(try context.fetch(FetchDescriptor<GymListingRecord>()).map(\.gymId))
        for gym in try context.fetch(FetchDescriptor<GymRecord>()) {
            gym.catalogRefreshedAt = nil
            guard gym.visibilityRaw == Self.synced else { continue }
            if gym.deletedAt != nil || (!gym.dirty && !remaining.contains(gym.id)) {
                context.delete(gym)
            } else {
                demote(gym, owner: owner)
            }
        }
        try context.save()
        return files
    }

    private func resetListing(_ listing: GymListingRecord, owner: UUID?) -> [String] {
        let file = listing.photoFile.map { [$0] } ?? []
        switch GymVisibility(rawValue: listing.visibilityRaw) {
        case .shared where listing.uploadStateRaw == UploadState.uploaded.rawValue:
            context.delete(listing)
            return file
        case .shared:
            demote(listing, owner: owner)
        case .synced where listing.deletedAt != nil:
            context.delete(listing)
        case .synced where !listing.dirty:
            context.delete(listing)
            return file
        case .synced:
            demote(listing, owner: owner)
        default:
            break
        }
        return []
    }

    /// Back to "This phone only", forgetting everything that tied the row to a server or an account except whose
    /// row the id still names (`demotedOwnerId`), so the next sign-in can tell whose rows these were.
    private func demote(_ listing: GymListingRecord, owner: UUID?) {
        listing.demotedOwnerId = owner
        listing.demotedDirty = owner != nil && listing.dirty
        listing.visibilityRaw = GymVisibility.device.rawValue
        listing.uploadStateRaw = UploadState.local.rawValue
        listing.uploadError = nil
        listing.duplicatesData = nil
        listing.remotePhotoPath = nil
        listing.remoteId = nil
        listing.serverUpdatedAt = nil
        listing.dirty = false
        listing.deletedAt = nil
    }

    private func demote(_ gym: GymRecord, owner: UUID?) {
        gym.demotedOwnerId = owner
        gym.demotedDirty = owner != nil && gym.dirty
        gym.visibilityRaw = GymVisibility.device.rawValue
        gym.serverUpdatedAt = nil
        gym.dirty = false
        gym.deletedAt = nil
    }
}
