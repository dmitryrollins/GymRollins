import CryptoKit
import Foundation

/// `manifest.json` in the `exercise-photos` bucket, written by `scripts/upload-photos.mjs`:
/// `{ "version": 1, "updatedAt": "<ISO>", "photos": { "<id>": <frames> }, "rev": { "<id>": "<hex>" },
/// "kinds": { "<kindId>": "<hex>" } }`.
/// It tells the app which exercises and equipment kinds have hosted photos, so it never lists the bucket.
struct StoragePhotoManifest: Sendable, Equatable {
    static let supportedVersion = 1
    /// No exercise has more frames than this (start/end today; room for a few more).
    static let maxFrames = 8
    /// The full library (~1,000 exercises) is far below this; anything bigger isn't our manifest.
    static let maxBytes = 1_024 * 1_024

    enum ParseError: Error, Equatable {
        case tooLarge
        case unsupportedVersion(Int)
    }

    /// Exercise id -> frame count (frames 0..<count exist).
    let photos: [String: Int]
    /// Exercise id -> content revision, appended as `?v=` so a regenerated photo bypasses long-lived caches.
    let rev: [String: String]

    /// Equipment kind id -> content revision of `kind-<kindId>.jpg`. A kind is listed only when its photo is hosted.
    let kinds: [String: String]

    init(photos: [String: Int], rev: [String: String] = [:], kinds: [String: String] = [:]) {
        self.photos = photos
        self.rev = rev
        self.kinds = kinds
    }

    private struct Wire: Decodable {
        let version: Int
        let photos: [String: Int]
        let rev: [String: String]
        let kinds: [String: String]

        private enum CodingKeys: String, CodingKey { case version, photos, rev, kinds }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            photos = try container.decode([String: Int].self, forKey: .photos)
            rev = Self.lenient(container, .rev)
            kinds = Self.lenient(container, .kinds)
        }

        /// A wrong shape is empty and a bad value drops only its entry: a bad `kinds` or `rev` must not lose the photos.
        private static func lenient(_ container: KeyedDecodingContainer<CodingKeys>,
                                    _ key: CodingKeys) -> [String: String] {
            let entries = (try? container.decodeIfPresent([String: Entry].self, forKey: key)) ?? nil
            return (entries ?? [:]).compactMapValues(\.value)
        }

        private struct Entry: Decodable {
            let value: String?
            init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(String.self) }
        }
    }

    /// Validates the JSON; entries with a malformed id, frame count or rev are dropped (not the whole manifest).
    init(data: Data) throws {
        guard data.count <= Self.maxBytes else { throw ParseError.tooLarge }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard wire.version == Self.supportedVersion else { throw ParseError.unsupportedVersion(wire.version) }
        photos = wire.photos.filter { id, frames in Self.isValidID(id) && (1...Self.maxFrames).contains(frames) }
        rev = wire.rev.filter { id, value in
            Self.isValidID(id) && Self.isValidRev(value)
        }
        kinds = wire.kinds.filter { id, value in Self.isValidKindID(id) && Self.isValidRev(value) }
    }

    static func isValidRev(_ rev: String) -> Bool {
        (1...64).contains(rev.count) && rev.allSatisfy(\.isHexDigit)
    }

    /// `^[a-z0-9-]{1,40}$`: the ids in `equipment-kinds.json`.
    static func isValidKindID(_ id: String) -> Bool {
        (1...40).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    static func isValidID(_ id: String) -> Bool {
        (1...12).contains(id.count) && id.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// Fetches the manifest (at most once per launch, driven by `HostedPhotoProvider.start`) and keeps the last
/// good copy on disk, so the app shows hosted photos immediately on the next launch and offline
/// (stale-while-revalidate). Any failure keeps the cached copy; the app then falls back to bundled/free photos.
struct StoragePhotoManifestLoader: Sendable {
    let manifestURL: URL
    let cacheFile: URL
    let policy: PhotoURLPolicy
    let session: URLSession

    init(manifestURL: URL, cacheDirectory: URL, policy: PhotoURLPolicy, session: URLSession) {
        self.manifestURL = manifestURL
        // Keyed by URL, so switching between the local stack and a cloud project never mixes manifests.
        let hash = SHA256.hash(data: Data(manifestURL.absoluteString.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        cacheFile = cacheDirectory.appendingPathComponent("manifest-\(hash).json")
        self.policy = policy
        self.session = session
    }

    /// The app's loader: no URLCache (the disk copy is the cache), short timeout, Caches/ExercisePhotoManifest.
    static func standard(manifestURL: URL, policy: PhotoURLPolicy) -> StoragePhotoManifestLoader {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return StoragePhotoManifestLoader(
            manifestURL: manifestURL,
            cacheDirectory: caches.appendingPathComponent("ExercisePhotoManifest", isDirectory: true),
            policy: policy, session: URLSession(configuration: config))
    }

    /// The last good manifest on disk, nil when there is none or it no longer parses.
    func cached() -> StoragePhotoManifest? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        return try? StoragePhotoManifest(data: data)
    }

    /// Downloads and validates the manifest, then caches it. nil on any failure (logged; the cache is kept).
    func refresh() async -> StoragePhotoManifest? {
        guard policy.allows(manifestURL) else {
            MediaLog.log.error("Photo manifest URL not allowed by the photo URL policy")
            return nil
        }
        do {
            let (data, response) = try await session.data(from: manifestURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw ExercisePhotoError.badResponse(status) }
            let manifest = try StoragePhotoManifest(data: data)
            store(data)
            return manifest
        } catch {
            MediaLog.log.error("Photo manifest refresh failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Best effort: a failed cache write (disk full, unwritable) still lets this launch use the fresh manifest.
    private func store(_ data: Data) {
        do {
            try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: cacheFile, options: .atomic)
        } catch {
            MediaLog.log.error("Photo manifest cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
