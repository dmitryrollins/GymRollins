import Foundation
import GymData
import Supabase

extension SupabaseGymCatalogTransport {
    /// Removes every photo the caller owns, listed on a listing or not (`my_gym_photos()` goes by owner). Stops at the
    /// first real failure. An object that is already gone isn't one: Storage just leaves it out of its answer.
    public func deleteAllPhotos() async throws {
        guard client.auth.currentSession != nil else { throw GymCatalogError.signedOut }
        try await OwnedPhotos.removeEverything(list: {
            let data = try await call { try await client.rpc("my_gym_photos").execute().data }
            return try OwnedPhotos.list(from: data)
        }, remove: { bucket, names in
            _ = try await call { try await client.storage.from(bucket).remove(paths: names) }
        })
    }

    /// Clears the photo names from the caller's own listings, so they don't name objects `deleteAllPhotos` is about to
    /// remove. Nothing else changes.
    public func detachAllPhotos() async throws {
        guard client.auth.currentSession != nil else { throw GymCatalogError.signedOut }
        _ = try await call { try await client.rpc("detach_my_gym_photos").execute().data }
    }
}
