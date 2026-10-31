import Foundation
import Supabase

/// Private gyms and listings (`visibility = 'private'`; RLS limits them to the owner) and their photos in
/// `gym-photos-private`. Reads name their columns: the table's grants don't include `owner_id`.
extension SupabaseTransport {
    static let privatePhotoBucket = "gym-photos-private"

    public func push(gyms: [GymDTO]) async throws -> [RowAck] {
        let rows: [AckRow] = try await upsert(gyms, into: "gyms", onConflict: "id", returning: "id,updated_at")
        return rows.map { RowAck(id: $0.id, updatedAt: $0.updatedAt) }
    }

    public func push(gymListings: [GymListingDTO]) async throws -> [RowAck] {
        do {
            let rows: [AckRow] = try await upsert(gymListings, into: "gym_equipment", onConflict: "id",
                                                  returning: "id,updated_at")
            return rows.map { RowAck(id: $0.id, updatedAt: $0.updatedAt) }
        } catch let error as PostgrestError where error.message == "photo_missing" {
            throw PrivatePhotoMissing()
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
}

private struct AckRow: Decodable {
    let id: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey { case id, updatedAt = "updated_at" }
}
