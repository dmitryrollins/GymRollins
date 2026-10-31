import Foundation
import Supabase

/// Private gyms and listings (`visibility = 'private'`; RLS limits them to the owner) and their photos in
/// `gym-photos-private`. Reads name their columns: the table's grants don't include `owner_id`.
extension SupabaseTransport {
    static let privatePhotoBucket = "gym-photos-private"

    public func push(gyms: [GymDTO]) async throws -> [RowAck] {
        let rows: [AckRow] = try await Self.mappingGymRefusals {
            try await upsert(gyms, into: "gyms", onConflict: "id", returning: "id,updated_at")
        }
        return rows.map { RowAck(id: $0.id, updatedAt: $0.updatedAt) }
    }

    public func push(gymListings: [GymListingDTO]) async throws -> [RowAck] {
        do {
            let rows: [AckRow] = try await Self.mappingGymRefusals {
                try await upsert(gymListings, into: "gym_equipment", onConflict: "id", returning: "id,updated_at")
            }
            return rows.map { RowAck(id: $0.id, updatedAt: $0.updatedAt) }
        } catch let error as PostgrestError where error.message == "photo_missing" {
            throw PrivatePhotoMissing()
        }
    }

    static let limitMessages = [
        "too_many_gyms": "You've reached the limit of gyms on one account.",
        "too_many_listings": "You've reached the limit of equipment on one account.",
    ]

    /// What the server refusing one gym or listing means for that row alone, or nil when it is something else.
    /// 42501 here is a row id that another account's row already holds (RLS hides it from this one), and the
    /// limits are named `P0001` errors. Neither says anything about the session, unlike 42501 on other tables, so
    /// `SyncRecordRejected.isRowRejection` is left as it is and the mapping lives here.
    static func gymRefusal(for error: PostgrestError) -> SyncRecordRejected? {
        if error.code == "42501" {
            return SyncRecordRejected(code: "42501", message: "This belongs to another account and can't be synced.")
        }
        if error.code == "P0001", let message = limitMessages[error.message] {
            return SyncRecordRejected(code: "P0001", message: message)
        }
        return nil
    }

    static func mappingGymRefusals<R>(_ call: () async throws -> R) async throws -> R {
        do {
            return try await call()
        } catch let error as PostgrestError {
            throw gymRefusal(for: error) ?? error
        }
    }

    public func pullGyms(since: Date?) async throws -> [GymDTO] {
        try await pull("gyms", select: GymDTO.columns, only: ("visibility", "private"), since: since)
    }

    public func pullGymListings(since: Date?) async throws -> [GymListingDTO] {
        try await pull("gym_equipment", select: GymListingDTO.columns, only: ("visibility", "private"), since: since)
    }

    public func uploadPrivatePhoto(_ data: Data, name: String) async throws -> String {
        let stored = name.lowercased()
        do {
            _ = try await client.storage.from(Self.privatePhotoBucket).upload(
                stored, data: data, options: FileOptions(cacheControl: "31536000", contentType: "image/jpeg",
                                                         upsert: false))
        } catch let failure as StorageError where GymCatalogErrors.isDuplicateUpload(failure) {
            // The same photo, uploaded by an earlier try whose answer was lost.
        }
        return stored
    }

    public func downloadPrivatePhoto(path: String) async throws -> Data {
        try await client.storage.from(Self.privatePhotoBucket).download(path: path.lowercased())
    }

    public func deletePrivatePhoto(path: String) async throws {
        _ = try await client.storage.from(Self.privatePhotoBucket).remove(paths: [path.lowercased()])
    }
}

private struct AckRow: Decodable {
    let id: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey { case id, updatedAt = "updated_at" }
}
