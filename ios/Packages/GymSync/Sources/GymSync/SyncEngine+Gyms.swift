import Foundation
import GymData

// Private gyms and listings: pushed and pulled before workouts, gyms before the listings that point at them.
extension SyncEngine {
    // MARK: Push

    func pushGyms() async throws {
        let sent = try store.dirtyGyms().map(\.value.id)
        try await pushBatch(.gyms, rows: try store.dirtyGyms(), key: { $0.value.id.uuidString }, send: {
            try await self.transport.push(gyms: $0.map(GymDTO.init))
        })
        // A listing refused because its gym was refused is tried again once the gym is accepted.
        let stillDirty = Set(try store.dirtyGyms().map(\.value.id))
        for id in sent where !stillDirty.contains(id) { try store.unblockListings(ofGym: id) }
        try await pushGymListings()
    }

    /// One listing per request: each may need its photo uploaded first, and a failure there must only hold back
    /// that listing. A listing whose upload failed stays dirty and the round goes on.
    private func pushGymListings() async throws {
        for row in try store.dirtyGymListings() {
            let id = row.value.id.uuidString
            guard !store.isSyncBlocked(.gymListings, id: id, clientUpdatedAt: row.clientUpdatedAt) else { continue }
            guard let sendable = try await withUploadedPhoto(row) else { continue }
            do {
                let acks = try await transport.push(gymListings: [GymListingDTO(sendable)])
                try ensureLive()
                if let ack = acks.first {
                    try store.markSynced(.gymListings, id: id, clientUpdatedAt: row.clientUpdatedAt,
                                         serverUpdatedAt: ack.updatedAt)
                    if row.deletedAt != nil { try await deleteServerPhoto(row.value.remotePhotoPath) }
                }
            } catch let rejected as SyncRecordRejected {
                try ensureLive()
                recordRejection(rejected, entity: .gymListings, id: id, clientUpdatedAt: row.clientUpdatedAt)
            } catch is PrivatePhotoMissing {
                // The bucket lost the picture: forget its name so the next round uploads it again.
                try ensureLive()
                try store.setRemotePhotoPath(listingId: row.value.id, path: nil)
            }
        }
    }

    /// Best effort: a picture left in the bucket is logged, and neither blocks the round nor keeps the deleted row.
    private func deleteServerPhoto(_ path: String?) async throws {
        guard let path else { return }
        do {
            try await transport.deletePrivatePhoto(path: path)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ensureLive()
            Self.log.error("Delete of a listing photo on the server failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The row to send, with its picture uploaded to the private bucket. The name is stored the moment the upload
    /// succeeds, so a retry doesn't upload twice. Nil when the upload failed: the row stays dirty.
    private func withUploadedPhoto(_ row: SyncRow<SyncedListing>) async throws -> SyncRow<SyncedListing>? {
        let value = row.value
        guard row.deletedAt == nil, value.remotePhotoPath == nil, let file = value.photoFile else { return row }
        guard let photos, let data = photos.data(file: file) else {
            Self.log.error("Sent listing \(value.id.uuidString, privacy: .public) without its photo: file unavailable")
            return row
        }
        let name = "\(UUID().uuidString.lowercased()).jpg"
        do {
            let stored = try await transport.uploadPrivatePhoto(data, name: name)
            try ensureLive()
            try store.setRemotePhotoPath(listingId: value.id, path: stored)
            return SyncRow(value: value.withRemotePhotoPath(stored), clientUpdatedAt: row.clientUpdatedAt,
                           deletedAt: row.deletedAt, serverUpdatedAt: row.serverUpdatedAt)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ensureLive()
            Self.log.error("Upload of a listing photo failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Pull

    func pullGyms() async throws {
        try await pull(.gyms, fetch: { try await self.transport.pullGyms(since: $0) }, apply: {
            self.deletePhotoFiles(try self.store.applyRemote(gyms: $0.map { $0.toDomain() }))
        })
        try await pull(.gymListings, fetch: { try await self.transport.pullGymListings(since: $0) }, apply: {
            self.deletePhotoFiles(try self.store.applyRemote(gymListings: $0.compactMap { $0.toDomain() }))
        })
        try await fetchMissingGymPhotos()
    }

    /// Downloads the pictures of synced listings that have none on this phone. Driven by local state rather than
    /// by the pulled rows, so a download that failed is tried again at the next pull.
    private func fetchMissingGymPhotos() async throws {
        guard let photos else { return }
        for fetch in try store.listingsMissingPhoto() {
            do {
                let data = try await transport.downloadPrivatePhoto(path: fetch.path)
                try ensureLive()
                let file = "\(UUID().uuidString).jpg"
                try photos.save(data, file: file)
                // The user may have attached a picture while this downloaded; theirs stays.
                guard try store.setPhotoFile(listingId: fetch.listingId, file: file) else {
                    try photos.delete(file: file)
                    continue
                }
                noteRemoteChanges()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try ensureLive()
                Self.log.error("Download of a listing photo failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func deletePhotoFiles(_ files: [String]) {
        for file in files {
            do { try photos?.delete(file: file) } catch {
                Self.log.error("Delete of a gym photo failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
