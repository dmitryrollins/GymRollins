import Foundation
import GymCore
import Testing
import UIKit
@testable import GymRollins

/// GymRollins' own exercise photos shipped in the app bundle (`own-<exerciseId>-<frame>.jpg`), which win over the
/// free-exercise-db stopgap.
@Suite struct BundledOwnPhotoTests {
    private func exercise(_ id: String) -> Exercise {
        Exercise(id: id, name: "x", bodyPart: "upper arms", equipment: "ez barbell", target: "triceps")
    }

    private let root = URL(fileURLWithPath: "/App.app", isDirectory: true)
    private func file(_ name: String) -> URL { root.appendingPathComponent(name) }

    @Test func groupsFramesByExerciseInOrder() throws {
        let provider = BundledOwnPhotoProvider(files: [
            file("own-0453-1.jpg"), file("own-0453-0.jpg"), file("own-0215-0.jpg"),
        ])
        let media = try #require(provider.media(for: exercise("0453")))
        #expect(media.source == .own)
        #expect(media.photos.map(\.lastPathComponent) == ["own-0453-0.jpg", "own-0453-1.jpg"])
        #expect(provider.media(for: exercise("0215"))?.photos.count == 1)
        #expect(provider.media(for: exercise("0025")) == nil)
    }

    @Test func ignoresFilesThatAreNotOwnPhotos() {
        let provider = BundledOwnPhotoProvider(files: [
            file("exercise-photos.json"), file("own-0453.jpg"), file("own-0453-x.jpg"), file("own--0.jpg"),
            file("own-0453-0.png"), file("OWN-0453-0.jpg"),
        ])
        #expect(provider.media(for: exercise("0453")) == nil)
    }

    @Test func appBundleShipsTheEZBarTricepsExtensionPhotos() throws {
        let provider = BundledOwnPhotoProvider.bundled()
        let media = try #require(provider.media(for: exercise("0453")))
        #expect(media.photos.count == 2)
        #expect(media.photos.allSatisfy { UIImage(contentsOfFile: $0.path()) != nil })
    }

    @Test func realServiceShowsOwnPhotosBeforeFreeExerciseDB() throws {
        let service = ExerciseMediaService.make(options: LaunchOptions(arguments: []))
        #expect(service.provider.media(for: exercise("0453"))?.source == .own)
        #expect(service.provider.media(for: exercise("0025"))?.source == .freeExerciseDB)
    }

    @Test func storeLoadsBundledPhotoWithoutNetwork() async throws {
        let store = ExercisePhotoStore(session: URLSession(configuration: .ephemeral),
                                       directory: FileManager.default.temporaryDirectory
                                           .appendingPathComponent("own-photo-test-\(UUID())"))
        let url = try #require(BundledOwnPhotoProvider.bundled().media(for: exercise("0453"))?.photos.first)
        let image = try await store.image(for: url, maxPixelSize: 200)
        #expect(max(image.size.width, image.size.height) <= 200)
    }

    @Test func storeRefusesFileURLsOutsideTheAppBundle() async throws {
        let store = ExercisePhotoStore(session: URLSession(configuration: .ephemeral),
                                       directory: FileManager.default.temporaryDirectory
                                           .appendingPathComponent("own-photo-test-\(UUID())"))
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("evil.jpg")
        await #expect(throws: ExercisePhotoError.insecureURL) {
            try await store.data(for: outside)
        }
        let escaping = try #require(Bundle.main.resourceURL).appendingPathComponent("../../../etc/hosts")
        await #expect(throws: ExercisePhotoError.insecureURL) {
            try await store.data(for: escaping)
        }
    }
}
