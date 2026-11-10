import Foundation
import GymCore
import Testing
import UIKit
@testable import GymRollins

/// End-to-end against a throwaway LOCAL Worker: `scripts/test-photo-hosting.sh` uploads two
/// generated photos (`own-<id>-0.jpg` 30×20, `own-<id>-1.jpg` 20×30) with `scripts/upload-photos.mjs`, then runs this
/// with `PHOTO_E2E=1`, `API_URL` and `PHOTO_E2E_ID`. Skipped in the normal test run (no network).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTO_E2E"] == "1", "needs scripts/test-photo-hosting.sh"))
struct StoragePhotoIntegrationTests {
    private let environment = ProcessInfo.processInfo.environment

    @Test func uploadedPhotosLoadThroughTheManifestAndProvider() async throws {
        let apiURL = try #require(environment["API_URL"].flatMap(URL.init(string:)))
        let id = try #require(environment["PHOTO_E2E_ID"])
        #expect(PhotoURLPolicy.isLocalDevHost(apiURL.host() ?? ""), "the E2E only ever runs against a local Worker")

        let policy = PhotoURLPolicy.forBuild(apiURL: apiURL)
        let session = URLSession(configuration: .ephemeral)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("photo-e2e-\(UUID().uuidString)")
        let loader = StoragePhotoManifestLoader(
            manifestURL: HostedPhotoProvider.manifestURL(apiURL: apiURL),
            cacheDirectory: temp.appendingPathComponent("manifest"), policy: policy, session: session)
        let (provider, refresh) = HostedPhotoProvider.start(apiURL: apiURL, loader: loader)
        await refresh.value

        let exercise = Exercise(id: id, name: "e2e", bodyPart: "chest", equipment: "barbell", target: "pectorals")
        let media = try #require(provider.media(for: exercise), "the uploaded exercise is in the bucket manifest")
        #expect(media.source == .own)
        #expect(media.photos.count == 2)

        let store = ExercisePhotoStore(session: session, directory: temp.appendingPathComponent("photos"), policy: policy)
        let start = try await store.image(for: media.photos[0], maxPixelSize: nil)
        let end = try await store.image(for: media.photos[1], maxPixelSize: nil)
        #expect(start.size == CGSize(width: 30, height: 20))
        #expect(end.size == CGSize(width: 20, height: 30))
        #expect(loader.cached() == provider.currentManifest, "the manifest is cached for the next launch")
    }
}
