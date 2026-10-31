import Foundation

enum GymPhotoCacheError: Error, Equatable { case notJPEG, tooBig, badResponse }

/// Downloads the picture of someone else's listing and keeps it like any gym photo (`GymPhotoStore`, with its 400 px
/// thumbnail). Only a JPEG of at most 1 MB is accepted: the server promises that, and a phone doesn't take its word.
struct GymPhotoCache: Sendable {
    static let maxBytes = 1_000_000

    let store: GymPhotoStore
    /// Reads at most `maxBytes + 1` bytes from the URL, so an oversized file is refused without being held whole.
    let download: @Sendable (URL, Int) async throws -> Data

    /// Saves the picture and returns its file name.
    func fetch(from url: URL) async throws -> String {
        let data = try await download(url, Self.maxBytes + 1)
        return try save(data)
    }

    func save(_ data: Data) throws -> String {
        guard data.count <= Self.maxBytes else { throw GymPhotoCacheError.tooBig }
        guard Self.isJPEG(data) else { throw GymPhotoCacheError.notJPEG }
        let thumbnail = try GymPhotoProcessor.thumbnail(ofCleaned: data)
        return try store.save(ProcessedGymPhoto(jpeg: data, thumbnail: thumbnail))
    }

    /// JPEG files start with FF D8 FF.
    static func isJPEG(_ data: Data) -> Bool { data.starts(with: [0xFF, 0xD8, 0xFF]) }

    static func live(store: GymPhotoStore) -> Self {
        Self(store: store) { url, limit in
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GymPhotoCacheError.badResponse }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
            return data
        }
    }
}
