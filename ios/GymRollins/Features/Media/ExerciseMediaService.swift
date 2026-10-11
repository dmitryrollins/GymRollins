import Foundation
import Observation
import GymCore
import UIKit

/// The media provider plus the photo loader, chosen once at launch and held by `AppEnvironment`.
struct ExerciseMediaService: Sendable {
    let provider: any ExerciseMediaProvider
    let loader: any ExercisePhotoLoading
    /// Whether two photos crossfade on their own (off with Reduce Motion regardless).
    var autoCrossfade = true
    /// Bumped when the provider's answers change after launch (a fresh Storage manifest); photo views reload on it.
    var revision = MediaRevision()

    /// Real launches: own media (record URLs, then — with `PHOTO_HOSTING = storage` — photos in the Supabase
    /// `exercise-photos` bucket, then photos bundled in the app) -> free-exercise-db photos -> wger photos (only fill
    /// gaps; credited on the detail photo) -> (nil) illustration.
    /// Remote photos are downloaded on demand and cached; bundled ones load from the app. The storage manifest is
    /// refreshed once per launch in the background (the cached copy is used meanwhile).
    /// `-uiTesting` stays hermetic: no photos at all, or with `-uiTestingPhotos` locally rendered stand-ins.
    static func make(options: LaunchOptions, info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> ExerciseMediaService {
        #if DEBUG
        if options.uiTesting {
            // No auto crossfade: photos flip only on tap, so UI assertions on the label are deterministic.
            return options.uiTestingPhotos
                ? ExerciseMediaService(provider: StubPhotoProvider(), loader: StubPhotoLoader(), autoCrossfade: false)
                : ExerciseMediaService(provider: ChainedMediaProvider([]), loader: StubPhotoLoader(), autoCrossfade: false)
        }
        #endif
        let config = PhotoHostingConfig.resolve(info: info, environment: options.environment)
        let policy = PhotoURLPolicy.forBuild(supabaseURL: config.supabaseURL)
        let revision = MediaRevision()
        var providers: [any ExerciseMediaProvider] = [ExerciseRecordMediaProvider()]
        if let storage = storageProvider(config: config, policy: policy, onChange: { revision.bump() }) {
            providers.append(storage.provider)
        }
        providers.append(BundledOwnPhotoProvider.bundled())
        if let photos = FreeExerciseDBPhotoProvider.bundled() { providers.append(photos) }
        if let wger = WgerPhotoProvider.bundled() { providers.append(wger) }
        return ExerciseMediaService(provider: ChainedMediaProvider(providers),
                                    loader: ExercisePhotoStore.standard(policy: policy), revision: revision)
    }

    /// The Storage provider when this build hosts photos in Supabase Storage and the project URL may be fetched
    /// (https, or the local stack in DEBUG); nil otherwise (logged), so the bundled photos stay the source.
    /// `makeLoader` builds the manifest loader for the manifest URL (tests inject a stubbed session).
    static func storageProvider(
        config: PhotoHostingConfig, policy: PhotoURLPolicy,
        makeLoader: ((URL) -> StoragePhotoManifestLoader)? = nil,
        onChange: @escaping @MainActor @Sendable () -> Void = {}
    ) -> (provider: SupabaseStoragePhotoProvider, refresh: Task<Void, Never>)? {
        guard config.hosting == .storage else { return nil }
        guard let supabaseURL = config.supabaseURL else {
            MediaLog.log.error("PHOTO_HOSTING = storage but there is no valid SUPABASE_URL; using bundled photos")
            return nil
        }
        let manifestURL = SupabaseStoragePhotoProvider.manifestURL(supabaseURL: supabaseURL)
        guard policy.allows(manifestURL) else {
            MediaLog.log.error("PHOTO_HOSTING = storage needs an https SUPABASE_URL in this build; using bundled photos")
            return nil
        }
        let loader = makeLoader?(manifestURL)
            ?? StoragePhotoManifestLoader.standard(manifestURL: manifestURL, policy: policy)
        return SupabaseStoragePhotoProvider.start(supabaseURL: supabaseURL, loader: loader, onChange: onChange)
    }
}

/// A counter photo views include in their load task's id, so they reload when the media answers change after
/// launch (the Storage manifest arrived or changed) instead of keeping a fallback photo until they reappear.
@MainActor
@Observable
final class MediaRevision {
    private(set) var value = 0

    nonisolated init() {}

    func bump() { value += 1 }
}

#if DEBUG
/// UI tests (`-uiTesting -uiTestingPhotos`): every library exercise gets a start/end pair on a host that is never
/// contacted; `StubPhotoLoader` draws them.
struct StubPhotoProvider: ExerciseMediaProvider {
    /// Barbell bench press stands in for an AI-generated (own) photo, so UI tests see the "AI" badge.
    static let aiStubExerciseId = "0025"

    /// Lever seated fly stands in for a credited wger photo, so UI tests see the photo credit.
    static let wgerStubExerciseId = "0596"
    static let wgerStubCredit = PhotoCredit(
        title: "Butterfly", author: "Everkinetic", license: "CC-BY-SA 3",
        licenseURL: URL(string: "https://creativecommons.org/licenses/by-sa/3.0/deed.en"),
        sourceURL: URL(string: "https://wger.de/exercise/135/view-base"), modified: true)

    func media(for exercise: Exercise) -> ExerciseMedia? {
        guard !exercise.isCustom else { return nil }
        let base = "https://photos.uitest.invalid/\(exercise.id)/"
        let photos = [URL(string: base + "0.jpg"), URL(string: base + "1.jpg")].compactMap(\.self)
        switch exercise.id {
        case Self.aiStubExerciseId: return ExerciseMedia(photos: photos, animation: nil, source: .own)
        case Self.wgerStubExerciseId:
            return ExerciseMedia(photos: photos, animation: nil, source: .wger,
                                 credits: photos.map { _ in Self.wgerStubCredit })
        default: return ExerciseMedia(photos: photos, animation: nil, source: .freeExerciseDB)
        }
    }
}

/// Draws a flat placeholder photo locally (no network), darker for the end frame.
struct StubPhotoLoader: ExercisePhotoLoading {
    func image(for url: URL, maxPixelSize: CGFloat?) async throws -> UIImage {
        let side = min(maxPixelSize ?? 300, 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let color = url.lastPathComponent.hasPrefix("1") ? UIColor.systemTeal : UIColor.systemIndigo
        return UIGraphicsImageRenderer(size: CGSize(width: side * 1.5, height: side), format: format).image {
            color.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: side * 1.5, height: side))
        }
    }
}
#endif
