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

/// The borrowed picture and the saved one share one limited downloader.
@Suite struct GymPhotoDownloadLimitsTests {
    private let url = URL(string: "https://photos.uitest.invalid/gym-photos/a.jpg")!

    private func cache(_ result: @escaping @Sendable (URL, Int) async throws -> Data) -> GymPhotoCache {
        GymPhotoCache(store: GymPhotoStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("gym-cache-\(UUID())")), download: result)
    }

    @Test func aBorrowedPictureIsADecodedJPEGAndNothingIsSaved() async throws {
        let jpeg = GymPhotoFixture.jpegData()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gym-cache-\(UUID())")
        let cache = GymPhotoCache(store: GymPhotoStore(directory: dir)) { _, _ in jpeg }
        _ = try await cache.image(from: url)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path())) ?? []).isEmpty)
    }

    @Test func aBorrowedPictureObeysTheSameLimitsAsASavedOne() async throws {
        let png = cache { _, _ in Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) }
        await #expect(throws: GymPhotoCacheError.notJPEG) { _ = try await png.image(from: url) }
        let big = cache { _, _ in Data([0xFF, 0xD8, 0xFF]) + Data(count: GymPhotoCache.maxBytes) }
        await #expect(throws: GymPhotoCacheError.tooBig) { _ = try await big.image(from: url) }
    }

    @Test func theStreamIsCutAtTheLimitInsteadOfReadToTheEnd() async throws {
        let source = CountingBytes(header: [0xFF, 0xD8, 0xFF], total: 5_000_000)
        let data = try await GymPhotoCache.collect(source, limit: GymPhotoCache.maxBytes + 1)
        #expect(data.count == GymPhotoCache.maxBytes + 1)
        #expect(source.pulled.value == GymPhotoCache.maxBytes + 1)
    }

    @Test func aStreamThatIsNotAJPEGIsDroppedAfterItsFirstBytes() async throws {
        let source = CountingBytes(header: [0x89, 0x50, 0x4E, 0x47], total: 5_000_000)
        await #expect(throws: GymPhotoCacheError.notJPEG) {
            _ = try await GymPhotoCache.collect(source, limit: GymPhotoCache.maxBytes + 1)
        }
        #expect(source.pulled.value <= 3, "it never downloaded the rest")
    }

    @Test func theLiveDownloadHasATotalDeadline() {
        let configuration = GymPhotoCache.liveConfiguration
        #expect(configuration.timeoutIntervalForResource > 0 && configuration.timeoutIntervalForResource <= 30)
        #expect(configuration.timeoutIntervalForRequest <= 15)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}

/// `total` bytes that start with `header`, counting how many were taken.
struct CountingBytes: AsyncSequence {
    typealias Element = UInt8
    let header: [UInt8]
    let total: Int
    let pulled = Counter()

    struct Iterator: AsyncIteratorProtocol {
        let source: CountingBytes
        var index = 0
        mutating func next() async -> UInt8? {
            guard index < source.total else { return nil }
            defer { index += 1 }
            source.pulled.bump()
            return index < source.header.count ? source.header[index] : 0
        }
    }

    func makeAsyncIterator() -> Iterator { Iterator(source: self) }
}

private actor LimitBox {
    private(set) var value = 0
    func set(_ limit: Int) { value = limit }
}
