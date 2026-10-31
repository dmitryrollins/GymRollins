import Foundation
import GymData
import Supabase

/// An object the caller owns in one of the gym buckets, as `my_gym_photos()` lists it.
struct OwnedPhoto: Decodable, Equatable, Hashable {
    let bucketId: String
    let name: String

    enum CodingKeys: String, CodingKey { case bucketId = "bucket_id", name }
}

extension SupabaseGymCatalogTransport {
    /// Storage's remove takes a list; a few at a time keeps each request small.
    static let removeBatch = 100
    /// `my_gym_photos()` is capped by PostgREST's `max_rows` (1000), so a user with more is read again after each pass.
    static let maxPhotoPasses = 20

    /// Removes every photo the caller owns, listed on a listing or not (`my_gym_photos()` goes by owner). Stops at the
    /// first real failure. An object that is already gone isn't one: Storage just leaves it out of its answer.
    public func deleteAllPhotos() async throws {
        guard client.auth.currentSession != nil else { throw GymCatalogError.signedOut }
        try await Self.removeEverything(list: {
            let data = try await call { try await client.rpc("my_gym_photos").execute().data }
            return try Self.ownedPhotos(from: data)
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

    /// Lists, removes, and lists again until nothing is left. The same objects twice in a row mean Storage is not
    /// removing them, and `maxPasses` bounds a user whose photos keep appearing; either ends in a refusal instead of
    /// a loop.
    static func removeEverything(maxPasses: Int = maxPhotoPasses, batchSize: Int = removeBatch,
                                 list: () async throws -> [OwnedPhoto],
                                 remove: (_ bucket: String, _ names: [String]) async throws -> Void) async throws {
        var previous: Set<OwnedPhoto> = []
        for _ in 0..<maxPasses {
            let photos = try await list()
            if photos.isEmpty { return }
            guard Set(photos) != previous else { throw GymCatalogError.rejected("photos remain") }
            previous = Set(photos)
            try await removeAll(photos, batchSize: batchSize, remove: remove)
        }
        throw GymCatalogError.rejected("photos remain")
    }

    static func ownedPhotos(from data: Data) throws -> [OwnedPhoto] {
        do {
            return try JSONDecoder().decode([OwnedPhoto].self, from: data)
        } catch {
            throw GymCatalogError.rejected("unreadable photo list")
        }
    }

    static func removeAll(_ photos: [OwnedPhoto], batchSize: Int = removeBatch,
                          remove: (_ bucket: String, _ names: [String]) async throws -> Void) async throws {
        var buckets: [String] = []
        for photo in photos where !buckets.contains(photo.bucketId) { buckets.append(photo.bucketId) }
        for bucket in buckets {
            let names = photos.filter { $0.bucketId == bucket }.map(\.name)
            for start in stride(from: 0, to: names.count, by: batchSize) {
                try await remove(bucket, Array(names[start..<min(start + batchSize, names.count)]))
            }
        }
    }
}
