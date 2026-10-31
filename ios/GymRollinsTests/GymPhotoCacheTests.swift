import Foundation
import Testing
@testable import GymRollins

@Suite struct GymPhotoCacheTests {
    private func cache(_ result: @escaping @Sendable (URL, Int) async throws -> Data) -> (GymPhotoCache, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gym-cache-\(UUID())")
        return (GymPhotoCache(store: GymPhotoStore(directory: dir), download: result), dir)
    }

    private func files(_ dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path())) ?? []
    }

    private let url = URL(string: "https://photos.uitest.invalid/gym-photos/a.jpg")!

    @Test func aJPEGIsSavedWithItsThumbnail() async throws {
        let jpeg = GymPhotoFixture.jpegData()
        let (cache, dir) = cache { _, _ in jpeg }
        let name = try await cache.fetch(from: url)
        #expect(name.hasSuffix(".jpg"))
        #expect(files(dir).count == 2, "the photo and its thumbnail")
    }

    @Test func somethingThatIsNotAJPEGIsRefused() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        let (cache, dir) = cache { _, _ in png }
        await #expect(throws: GymPhotoCacheError.notJPEG) { _ = try await cache.fetch(from: url) }
        #expect(files(dir).isEmpty)
    }

    @Test func aFileOverOneMegabyteIsRefused() async throws {
        let big = Data([0xFF, 0xD8, 0xFF]) + Data(count: GymPhotoCache.maxBytes)
        let (cache, dir) = cache { _, _ in big }
        await #expect(throws: GymPhotoCacheError.tooBig) { _ = try await cache.fetch(from: url) }
        #expect(files(dir).isEmpty)
    }

    @Test func aFileOfExactlyOneMegabyteIsNotTooBig() throws {
        let edge = Data([0xFF, 0xD8, 0xFF]) + Data(count: GymPhotoCache.maxBytes - 3)
        let (cache, _) = cache { _, _ in edge }
        // Not decodable as an image, but the size and type checks pass: the failure comes from the thumbnail step.
        #expect(throws: GymPhotoError.self) { _ = try cache.save(edge) }
    }

    @Test func theDownloadIsToldItsLimit() async throws {
        let seen = LimitBox()
        let jpeg = GymPhotoFixture.jpegData()
        let (cache, _) = cache { _, limit in
            await seen.set(limit)
            return jpeg
        }
        _ = try await cache.fetch(from: url)
        #expect(await seen.value == GymPhotoCache.maxBytes + 1)
    }
}

private actor LimitBox {
    private(set) var value = 0
    func set(_ limit: Int) { value = limit }
}
