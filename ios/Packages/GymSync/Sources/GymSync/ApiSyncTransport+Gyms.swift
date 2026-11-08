import Foundation
import GymCore
import GymData

/// Private gyms and listings (`/v1/sync/gyms`, `/v1/sync/gym-listings`; server/src/sync/entities.ts) and their photos
/// in `gym-photos-private` (`/v1/photos/private/<name>`). The server keeps them to the session's account, stamps the
/// owner and author itself, and nests a pulled listing's kind as `equipment_items.kind_id`, which `GymListingDTO`
/// reads.
extension ApiSyncTransport {
    public func push(gyms: [GymDTO]) async throws -> [RowAck] {
        try await push(gyms, to: "gyms")
    }

    /// A listing whose photo the server doesn't hold as this account's (422 `photo_missing`) throws
    /// `PrivatePhotoMissing`, so the phone uploads it again. The caps (`too_many_gyms`, `too_many_listings`) and refused values come back as
    /// `SyncRecordRejected` with the server's words, which are the app's.
    public func push(gymListings: [GymListingDTO]) async throws -> [RowAck] {
        do {
            return try await push(gymListings, to: "gym-listings")
        } catch let refused as SyncRecordRejected where refused.code == "photo_missing" {
            throw PrivatePhotoMissing()
        }
    }

    public func pullGyms(since: Date?) async throws -> [GymDTO] {
        try await pull("gyms", tiebreak: "id", since: since)
    }

    public func pullGymListings(since: Date?) async throws -> [GymListingDTO] {
        try await pull("gym-listings", tiebreak: "id", since: since)
    }

    /// Uploads as JPEG; a name the caller already uploaded (409) counts as uploaded.
    public func uploadPrivatePhoto(_ data: Data, name: String) async throws -> String {
        let stored = try Self.privatePhotoPath(name)
        do {
            _ = try await api.data("PUT", stored, body: data, contentType: "image/jpeg")
        } catch let failure as ApiError where failure.status == 409 {
            // The same photo, uploaded by an earlier try whose answer was lost.
        }
        return name.lowercased()
    }

    /// Served to its owner only, never cached: `ApiClient`'s session has no URL cache, and the server says no-store.
    public func downloadPrivatePhoto(path: String) async throws -> Data {
        try await api.data("GET", Self.privatePhotoPath(path)).body
    }

    public func deletePrivatePhoto(path: String) async throws {
        _ = try await api.data("DELETE", Self.privatePhotoPath(path))
    }

    /// `/v1/photos/private/<uuid>.jpg`. Any other name is refused before a request is made: a name like `../x` would
    /// take the session's token to another path.
    static func privatePhotoPath(_ name: String) throws -> String {
        guard GymPhotoName.isValid(name) else { throw URLError(.badURL) }
        return "/v1/photos/private/\(name.lowercased())"
    }
}
