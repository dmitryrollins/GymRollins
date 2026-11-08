import Foundation
import GymData

/// An object the caller owns in one of the gym buckets, as `GET /v1/photos/mine` (and `my_gym_photos()` before it)
/// lists it.
struct OwnedPhoto: Decodable, Equatable, Hashable {
    let bucketId: String
    let name: String

    enum CodingKeys: String, CodingKey { case bucketId = "bucket_id", name }
}

/// Removing every photo an account owns, before the account is deleted: list, remove, list again until nothing is
/// left. Shared by the API's catalogue transport and, until plan 30 deletes it, the Supabase one.
enum OwnedPhotos {
    /// A remove call takes a few names at a time, so each request stays small.
    static let removeBatch = 100
    /// A list is capped (PostgREST's `max_rows`, the API's 1,000 rows), so a user with more is listed again after each
    /// pass.
    static let maxPhotoPasses = 20

    /// Lists, removes, and lists again until nothing is left. The same objects twice in a row mean the server is not
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

    static func list(from data: Data) throws -> [OwnedPhoto] {
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
