import Foundation
import GymCore
import Synchronization

/// GymRollins' own photos hosted in the public `exercise-photos` Supabase Storage bucket (uploaded by
/// `scripts/upload-photos.mjs`). Which exercises have photos comes from the bucket's manifest; the photo URLs are
/// `<SUPABASE_URL>/storage/v1/object/public/exercise-photos/own-<id>-<frame>.jpg?v=<rev>`. Without a manifest (first
/// launch offline, fetch failed) it answers nil, so the chain falls through to bundled / free-exercise-db photos.
final class SupabaseStoragePhotoProvider: ExerciseMediaProvider, Sendable {
    static let bucket = "exercise-photos"

    /// `<SUPABASE_URL>/storage/v1/object/public/exercise-photos/`
    let publicBaseURL: URL
    private let manifest: Mutex<StoragePhotoManifest?>

    init(supabaseURL: URL, manifest: StoragePhotoManifest? = nil) {
        publicBaseURL = Self.publicBaseURL(supabaseURL: supabaseURL)
        self.manifest = Mutex(manifest)
    }

    static func publicBaseURL(supabaseURL: URL) -> URL {
        supabaseURL.appending(path: "storage/v1/object/public/\(bucket)/", directoryHint: .isDirectory)
    }

    static func manifestURL(supabaseURL: URL) -> URL {
        publicBaseURL(supabaseURL: supabaseURL).appending(path: "manifest.json", directoryHint: .notDirectory)
    }

    var currentManifest: StoragePhotoManifest? { manifest.withLock { $0 } }

    /// Swaps in a fresher manifest; later `media(for:)` calls see it. Returns whether anything changed.
    @discardableResult
    func apply(_ fresh: StoragePhotoManifest) -> Bool {
        manifest.withLock { current in
            guard current != fresh else { return false }
            current = fresh
            return true
        }
    }

    func media(for exercise: Exercise) -> ExerciseMedia? {
        guard let entry = manifest.withLock({ current in
            current.flatMap { manifest in manifest.photos[exercise.id].map { ($0, manifest.rev[exercise.id]) } }
        }) else { return nil }
        let urls = (0..<entry.0).compactMap { photoURL(id: exercise.id, frame: $0, rev: entry.1) }
        return urls.isEmpty ? nil : ExerciseMedia(photos: urls, animation: nil, source: .own)
    }

    func photoURL(id: String, frame: Int, rev: String?) -> URL? {
        guard StoragePhotoManifest.isValidID(id), frame >= 0 else { return nil }
        let url = publicBaseURL.appending(path: "own-\(id)-\(frame).jpg", directoryHint: .notDirectory)
        guard let rev else { return url }
        return url.appending(queryItems: [URLQueryItem(name: "v", value: rev)])
    }

    /// The provider with the cached manifest (usable right away), plus a one-off refresh for this launch that swaps
    /// in the fresh manifest when it arrives and then calls `onChange` (the app bumps `MediaRevision`, so photo views
    /// already on screen reload). The returned task is only awaited by tests.
    static func start(supabaseURL: URL, loader: StoragePhotoManifestLoader,
                      onChange: @escaping @MainActor @Sendable () -> Void = {})
        -> (provider: SupabaseStoragePhotoProvider, refresh: Task<Void, Never>) {
        let provider = SupabaseStoragePhotoProvider(supabaseURL: supabaseURL, manifest: loader.cached())
        let refresh = Task.detached(priority: .utility) {
            if let fresh = await loader.refresh(), provider.apply(fresh) { await onChange() }
        }
        return (provider, refresh)
    }
}
