import Foundation
import UIKit

enum GymPhotoCacheError: Error, Equatable { case notJPEG, tooBig, badResponse }

/// Downloads the picture of someone else's listing and keeps it like any gym photo (`GymPhotoStore`, with its 400 px
/// thumbnail), or only shows it (`image(from:)`, for a picture borrowed from the catalogue). Both go through the
/// same limited download: a JPEG of at most 1 MB within a total deadline. The server promises that, and a phone
/// doesn't take its word.
struct GymPhotoCache: Sendable {
    static let maxBytes = 1_000_000

    let store: GymPhotoStore
    /// Reads at most `maxBytes + 1` bytes from the URL, so an oversized file is refused without being held whole.
    let download: @Sendable (URL, Int) async throws -> Data

    /// Saves the picture and returns its file name.
    func fetch(from url: URL) async throws -> String {
        try save(try await checkedData(from: url))
    }

    /// The picture to show, nothing saved. The same limits as `fetch`.
    func image(from url: URL) async throws -> UIImage {
        guard let image = UIImage(data: try await checkedData(from: url)) else { throw GymPhotoCacheError.notJPEG }
        return image
    }

    private func checkedData(from url: URL) async throws -> Data {
        let data = try await download(url, Self.maxBytes + 1)
        try Self.check(data)
        return data
    }

    private static func check(_ data: Data) throws {
        guard data.count <= maxBytes else { throw GymPhotoCacheError.tooBig }
        guard isJPEG(data) else { throw GymPhotoCacheError.notJPEG }
    }

    func save(_ data: Data) throws -> String {
        try Self.check(data)
        let thumbnail = try GymPhotoProcessor.thumbnail(ofCleaned: data)
        return try store.save(ProcessedGymPhoto(jpeg: data, thumbnail: thumbnail))
    }

    /// JPEG files start with FF D8 FF.
    static func isJPEG(_ data: Data) -> Bool { data.starts(with: [0xFF, 0xD8, 0xFF]) }

    /// A whole download may take 20 seconds, and no single wait for bytes more than 10: a slow server can't hold the
    /// queue (or a tile) for long.
    static var liveConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        return configuration
    }

    static func live(store: GymPhotoStore) -> Self {
        let session = URLSession(configuration: liveConfiguration)
        return Self(store: store) { url, limit in
            let (bytes, response) = try await session.bytes(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GymPhotoCacheError.badResponse }
            if response.expectedContentLength > Int64(limit) { throw GymPhotoCacheError.tooBig }
            return try await collect(bytes, limit: limit)
        }
    }

    /// Reads at most `limit` bytes. A body that doesn't start like a JPEG is dropped after its first bytes, and one
    /// longer than the limit is cut there, so neither is downloaded whole.
    static func collect<Bytes: AsyncSequence>(_ bytes: Bytes, limit: Int) async throws -> Data where Bytes.Element == UInt8 {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count == 3, !isJPEG(data) { throw GymPhotoCacheError.notJPEG }
            if data.count >= limit { break }
        }
        return data
    }
}
