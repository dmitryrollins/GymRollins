import Foundation
import ImageIO
import UIKit

enum GymPhotoCacheError: Error, Equatable { case notJPEG, tooBig, badResponse, tooManyPixels }

/// Downloads the picture of someone else's listing and keeps it like any gym photo (`GymPhotoStore`, with its 400 px
/// thumbnail), or only shows it (`image(from:)`, for a picture borrowed from the catalogue). Both go through the
/// same limited download: a JPEG of at most 1 MB and 4096 px a side within a total deadline. The server promises
/// that, and a phone doesn't take its word: a tiny file can claim 30000 x 30000 pixels, which would take gigabytes to
/// decode, for everyone who opens that gym.
struct GymPhotoCache: Sendable {
    static let maxBytes = 1_000_000
    static let maxPixelsPerSide = 4096
    /// A picture shown but not kept is decoded at this size at most.
    static let shownLongEdge = 1600

    let store: GymPhotoStore
    /// Reads at most `maxBytes + 1` bytes from the URL, so an oversized file is refused without being held whole.
    let download: @Sendable (URL, Int) async throws -> Data

    /// Saves the picture and returns its file name.
    func fetch(from url: URL) async throws -> String {
        try save(try await checkedData(from: url))
    }

    /// The picture to show, nothing saved. The same limits as `fetch`.
    func image(from url: URL) async throws -> UIImage {
        let data = try await checkedData(from: url)
        // Decoded as a downsampled thumbnail, so even a picture that passed the size check is never decoded whole.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.shownLongEdge,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw GymPhotoCacheError.notJPEG }
        return UIImage(cgImage: decoded)
    }

    private func checkedData(from url: URL) async throws -> Data {
        let data = try await download(url, Self.maxBytes + 1)
        try Self.check(data)
        return data
    }

    private static func check(_ data: Data) throws {
        guard data.count <= maxBytes else { throw GymPhotoCacheError.tooBig }
        guard isJPEG(data) else { throw GymPhotoCacheError.notJPEG }
        if let size = pixelSize(of: data), max(size.width, size.height) > CGFloat(maxPixelsPerSide) {
            throw GymPhotoCacheError.tooManyPixels
        }
    }

    /// The size the file's header claims, read without decoding: from the JPEG's own frame header, which does not
    /// depend on ImageIO being willing to open a file that big, and then from ImageIO. Nil when neither can read a
    /// header: such a file can't be decoded either, and the step that tries fails on its own.
    static func pixelSize(of data: Data) -> CGSize? {
        jpegFrameSize(of: data) ?? imageIOSize(of: data)
    }

    /// Walks the marker segments up to the first start-of-frame (SOF0...SOF15 but DHT, JPG and DAC), which holds the
    /// precision, height and width.
    private static func jpegFrameSize(of data: Data) -> CGSize? {
        let bytes = [UInt8](data.prefix(maxBytes))
        var index = 2
        while index + 3 < bytes.count {
            guard bytes[index] == 0xFF else { index += 1; continue }
            let marker = bytes[index + 1]
            if marker == 0xFF { index += 1; continue } // fill byte
            if marker == 0x01 || (0xD0...0xD8).contains(marker) { index += 2; continue } // no length
            if marker == 0xD9 || marker == 0xDA { return nil } // end of image, start of scan: no frame header came
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let isFrame = (0xC0...0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker)
            if isFrame, length >= 8, index + 8 < bytes.count {
                let height = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
                let width = Int(bytes[index + 7]) << 8 | Int(bytes[index + 8])
                return CGSize(width: width, height: height)
            }
            guard length >= 2 else { return nil }
            index += 2 + length
        }
        return nil
    }

    private static func imageIOSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
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
