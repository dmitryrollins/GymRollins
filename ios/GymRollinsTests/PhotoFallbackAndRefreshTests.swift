import Foundation
import GymCore
import Testing
import UIKit
@testable import GymRollins

/// Returns an image for URLs in `good`, throws for everything else (offline / evicted).
private struct GoodURLsLoader: ExercisePhotoLoading {
    let good: Set<URL>
    func image(for url: URL, maxPixelSize: CGFloat?) async throws -> UIImage {
        guard good.contains(url) else { throw URLError(.notConnectedToInternet) }
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    }
}

private struct Fixed: ExerciseMediaProvider {
    let media: ExerciseMedia?
    func media(for exercise: Exercise) -> ExerciseMedia? { media }
}

@MainActor
@Suite struct PhotoFallbackAndRefreshTests {
    private let bench = Exercise(id: "0453", name: "ez bar extension", bodyPart: "upper arms", equipment: "ez barbell",
                                 target: "triceps")
    private let hosted = ExerciseMedia(photos: [URL(string: "https://abc.supabase.co/own-0453-0.jpg")!,
                                                URL(string: "https://abc.supabase.co/own-0453-1.jpg")!],
                                       animation: nil, source: .own)
    private let bundled = ExerciseMedia(photos: [URL(fileURLWithPath: "/app/OwnPhotos/own-0453-0.jpg"),
                                                 URL(fileURLWithPath: "/app/OwnPhotos/own-0453-1.jpg")],
                                        animation: nil, source: .own)
    private let fedb = ExerciseMedia(photos: [URL(string: "https://cdn.example.com/a/0.jpg")!],
                                     animation: nil, source: .freeExerciseDB)

    // MARK: Fallback when hosted photos can't load

    @Test func chainListsEveryCandidateInOrder() {
        let chain = ChainedMediaProvider([Fixed(media: hosted), Fixed(media: nil), Fixed(media: bundled), Fixed(media: fedb)])
        #expect(chain.candidates(for: bench) == [hosted, bundled, fedb])
        #expect(chain.media(for: bench) == hosted)
        #expect(Fixed(media: nil).candidates(for: bench).isEmpty)
    }

    @Test func offlineHostedPhotosFallBackToTheBundledOnes() async {
        let chain = ChainedMediaProvider([Fixed(media: hosted), Fixed(media: bundled), Fixed(media: fedb)])
        let service = ExerciseMediaService(provider: chain, loader: GoodURLsLoader(good: Set(bundled.photos)))
        let model = ExercisePhotoModel()
        await model.load(bench, service: service, maxPixelSize: nil)
        #expect(model.frames.map(\.position) == [.start, .end])
        #expect(model.source == .own)
    }

    @Test func fallsThroughToFreeExerciseDBAndReportsItsSource() async {
        let chain = ChainedMediaProvider([Fixed(media: hosted), Fixed(media: fedb)])
        let service = ExerciseMediaService(provider: chain, loader: GoodURLsLoader(good: Set(fedb.photos)))
        let model = ExercisePhotoModel()
        await model.load(bench, service: service, maxPixelSize: nil)
        #expect(model.frames.count == 1)
        #expect(model.source == .freeExerciseDB)
    }

    @Test func aPartlyLoadedCandidateIsKept() async {
        let chain = ChainedMediaProvider([Fixed(media: hosted), Fixed(media: bundled)])
        let service = ExerciseMediaService(provider: chain, loader: GoodURLsLoader(good: [hosted.photos[0]]))
        let model = ExercisePhotoModel()
        await model.load(bench, service: service, maxPixelSize: nil)
        #expect(model.frames.map(\.position) == [.start], "a hosted start photo wins; no mixing of sources")
    }

    // MARK: Views reload when a fresh manifest arrives

    @Test func applyReportsWhetherTheManifestChanged() {
        let provider = SupabaseStoragePhotoProvider(supabaseURL: URL(string: "https://abc.supabase.co")!)
        #expect(provider.apply(StoragePhotoManifest(photos: ["0453": 2])))
        #expect(!provider.apply(StoragePhotoManifest(photos: ["0453": 2])))
        #expect(provider.apply(StoragePhotoManifest(photos: ["0453": 2], rev: ["0453": "ab"])))
    }

    @Test func revisionBumpsOnlyWhenTheRefreshChangedSomething() async {
        let host = PhotoTestData.uniqueHost()
        let cache = PhotoTestData.tempDir()
        HostStubURLProtocol.serve(host: host) { _ in .init(status: 200, body: PhotoTestData.manifest(["0453": 2])) }
        let loader = StoragePhotoManifestLoader(
            manifestURL: SupabaseStoragePhotoProvider.manifestURL(supabaseURL: URL(string: "https://\(host)")!),
            cacheDirectory: cache, policy: .httpsOnly, session: HostStubURLProtocol.session())

        let revision = MediaRevision()
        let first = SupabaseStoragePhotoProvider.start(supabaseURL: URL(string: "https://\(host)")!, loader: loader,
                                                       onChange: { revision.bump() })
        await first.refresh.value
        #expect(revision.value == 1, "no cache -> fresh manifest -> views reload")

        let second = SupabaseStoragePhotoProvider.start(supabaseURL: URL(string: "https://\(host)")!, loader: loader,
                                                        onChange: { revision.bump() })
        await second.refresh.value
        #expect(revision.value == 1, "same manifest as the cached one -> nothing reloads")
    }
}
