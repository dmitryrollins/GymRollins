import Foundation
import GymCore
import GymData

/// Shared photos (`/v1/photos/shared`), and the account's photos in both buckets before it is deleted
/// (`/v1/photos/mine`, `/v1/photos/detach`).
extension ApiGymCatalogTransport {
    /// Uploads to `gym-photos/<name>` as JPEG; a name already uploaded (409) counts as uploaded.
    public func uploadSharedPhoto(_ data: Data, name: String) async throws -> String {
        guard hasSession else { throw GymCatalogError.signedOut }
        let stored = try Self.photoName(name)
        do {
            _ = try await call {
                try await api.data("PUT", "/v1/photos/shared/\(stored)", body: data, contentType: "image/jpeg")
            }
        } catch UploadOutcome.alreadyThere {
            // The same photo, uploaded by an earlier try whose answer was lost.
        }
        return stored
    }

    public func deleteSharedPhoto(path: String) async throws {
        let stored = try Self.photoName(path)
        _ = try await call { try await api.data("DELETE", "/v1/photos/shared/\(stored)") }
    }

    /// Removes every photo the caller owns, listed on a listing or not (`/v1/photos/mine` goes by owner). Stops at the
    /// first real failure. A photo already gone isn't one: the server answers 204 for it.
    public func deleteAllPhotos() async throws {
        guard hasSession else { throw GymCatalogError.signedOut }
        try await OwnedPhotos.removeEverything(list: {
            let body = try await call { try await api.data("GET", "/v1/photos/mine").body }
            return try OwnedPhotos.list(from: GymCatalogRows.array(in: body, key: "rows"))
        }, remove: { bucket, names in
            let folder = bucket == "gym-photos" ? "shared" : "private"
            for name in names {
                _ = try await call { try await api.data("DELETE", "/v1/photos/\(folder)/\(try Self.photoName(name))") }
            }
        })
    }

    /// Clears the photo names from the caller's own listings, so they don't name objects `deleteAllPhotos` is about to
    /// remove. Nothing else changes.
    public func detachAllPhotos() async throws {
        guard hasSession else { throw GymCatalogError.signedOut }
        _ = try await call { try await api.data("POST", "/v1/photos/detach") }
    }

    /// A photo name as the API stores it: a lowercase UUID and `.jpg`. Anything else is refused here, because a name
    /// like `../x` would send the session's token to another path.
    static func photoName(_ name: String) throws -> String {
        guard GymPhotoName.isValid(name) else { throw GymCatalogError.rejected("not a photo name") }
        return name.lowercased()
    }
}
