import CryptoKit
import Foundation
import ImageIO
import UIKit

/// Loads exercise photos. The app uses `ExercisePhotoStore`; UI tests use a local stub (no network).
protocol ExercisePhotoLoading: Sendable {
    /// The photo at `url`, downsampled so its longest side is at most `maxPixelSize` pixels (nil = full size).
    func image(for url: URL, maxPixelSize: CGFloat?) async throws -> UIImage
}

enum ExercisePhotoError: Error, Equatable {
    case insecureURL
    case badResponse(Int)
    case notAnImage
}

/// Downloads photos on demand and keeps them in a size-capped file cache under Caches, so a photo seen once also
/// shows offline (and after relaunch). Files are only written once they decode as an image, so an error page or
/// captive-portal HTML is never cached. The OS may purge Caches under storage pressure; photos then re-download.
actor ExercisePhotoStore: ExercisePhotoLoading {
    static let defaultMaxBytes = 150 * 1_024 * 1_024
    /// Upstream JPEGs are ~50–150 KB; anything far bigger isn't one of them.
    static let maxPhotoBytes = 5 * 1_024 * 1_024

    private let session: URLSession
    private let directory: URL
    /// Photos shipped in the app are read from here; no other file URL is ever read.
    private let bundleRoot: URL?
    private let maxBytes: Int
    /// Which URLs may be downloaded: https only in production (see `PhotoURLPolicy`).
    private let policy: PhotoURLPolicy
    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [URL: Task<Data, any Error>] = [:]

    init(session: URLSession, directory: URL, maxBytes: Int = defaultMaxBytes,
         bundleRoot: URL? = Bundle.main.resourceURL, policy: PhotoURLPolicy = .httpsOnly) {
        self.session = session
        self.policy = policy
        self.directory = directory
        self.bundleRoot = bundleRoot
        self.maxBytes = maxBytes
        memory.totalCostLimit = 48 * 1_024 * 1_024
    }

    /// The app's store: its own URLSession (no shared URLCache; the file cache is the cache) in Caches/ExercisePhotos.
    static func standard(policy: PhotoURLPolicy = .httpsOnly) -> ExercisePhotoStore {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ExercisePhotoStore(session: URLSession(configuration: config),
                                  directory: caches.appendingPathComponent("ExercisePhotos", isDirectory: true),
                                  policy: policy)
    }

    func image(for url: URL, maxPixelSize: CGFloat?) async throws -> UIImage {
        let key = "\(url.absoluteString)#\(maxPixelSize.map { Int($0) } ?? 0)" as NSString
        if let cached = memory.object(forKey: key) { return cached }
        let data = try await data(for: url)
        guard let image = Self.decode(data, maxPixelSize: maxPixelSize) else { throw ExercisePhotoError.notAnImage }
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        memory.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// The photo's bytes: from the app bundle for photos shipped with the app; otherwise from disk if cached, or
    /// downloaded (once, even for concurrent callers) and cached.
    func data(for url: URL) async throws -> Data {
        if url.isFileURL { return try bundledData(url) }
        guard policy.allows(url) else { throw ExercisePhotoError.insecureURL }
        let file = fileURL(for: url)
        if let data = try? Data(contentsOf: file) {
            touch(file)
            return data
        }
        if let running = inFlight[url] { return try await running.value }
        let task = Task { try await self.download(url) }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        let data = try await task.value
        store(data, at: file)
        return data
    }

    /// Only files inside the app bundle's resources (after resolving `..` and symlinks) can be read.
    private func bundledData(_ url: URL) throws -> Data {
        guard let root = bundleRoot?.standardizedFileURL.resolvingSymlinksInPath().path(),
              url.standardizedFileURL.resolvingSymlinksInPath().path().hasPrefix(root.hasSuffix("/") ? root : root + "/")
        else { throw ExercisePhotoError.insecureURL }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maxPhotoBytes else { throw ExercisePhotoError.notAnImage }
        return data
    }

    private func download(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ExercisePhotoError.badResponse(status) }
        guard !data.isEmpty, data.count <= Self.maxPhotoBytes, UIImage(data: data) != nil else {
            throw ExercisePhotoError.notAnImage
        }
        return data
    }

    // MARK: Disk

    private func fileURL(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".img")
    }

    private func store(_ data: Data, at file: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            evictIfNeeded()
        } catch {
            // Not fatal: the photo still shows, it just re-downloads next time.
            MediaLog.log.error("Photo cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Marks a cache hit as recently used (eviction removes the least recently used files first).
    private func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path())
    }

    private func evictIfNeeded() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        else { return }
        let entries = files.compactMap { file -> (url: URL, size: Int, date: Date)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > maxBytes {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    // MARK: Decode

    /// Decodes (and, with `maxPixelSize`, downsamples) without keeping the full-size bitmap around for thumbnails.
    static func decode(_ data: Data, maxPixelSize: CGFloat?) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let maxPixelSize { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
