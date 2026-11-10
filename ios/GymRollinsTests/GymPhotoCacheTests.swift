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

/// A small JPEG whose header claims another size: nothing in the file is that big, but a decoder would believe the header
/// and allocate for it.
enum ClaimedSizeJPEG {
    static func make(width: Int, height: Int) -> Data {
        var bytes = [UInt8](GymPhotoFixture.jpegData())
        var index = 2
        while index + 9 < bytes.count {
            guard bytes[index] == 0xFF else { index += 1; continue }
            let marker = bytes[index + 1]
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            if marker == 0xC0 || marker == 0xC2 { // start of frame: precision, height, width
                bytes[index + 5] = UInt8(height >> 8); bytes[index + 6] = UInt8(height & 0xFF)
                bytes[index + 7] = UInt8(width >> 8); bytes[index + 8] = UInt8(width & 0xFF)
                return Data(bytes)
            }
            index += 2 + length
        }
        return Data(bytes)
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

/// A JPEG header can claim 30000 x 30000 pixels in a few hundred bytes. Decoding that takes gigabytes, for everyone who
/// opens the gym, so the header is read (never decoded) before the bytes are kept or shown.
@Suite struct GymPhotoPixelLimitTests {
    private let url = URL(string: "https://photos.uitest.invalid/gym-photos/a.jpg")!

    private func cache(_ data: Data) -> (GymPhotoCache, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gym-cache-\(UUID())")
        return (GymPhotoCache(store: GymPhotoStore(directory: dir)) { _, _ in data }, dir)
    }

    @Test func theFixtureReallyClaimsTheSizeItWasGiven() {
        let size = GymPhotoCache.pixelSize(of: ClaimedSizeJPEG.make(width: 30_000, height: 30_000))
        #expect(size == CGSize(width: 30_000, height: 30_000), "the test below tests what it says")
        #expect(ClaimedSizeJPEG.make(width: 30_000, height: 30_000).count < GymPhotoCache.maxBytes)
    }

    @Test func aHeaderClaimingHugeDimensionsIsRefusedAndNothingIsSaved() async throws {
        let (cache, dir) = cache(ClaimedSizeJPEG.make(width: 30_000, height: 30_000))
        await #expect(throws: GymPhotoCacheError.tooManyPixels) { _ = try await cache.fetch(from: url) }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path())) ?? []).isEmpty)
    }

    @Test func aBorrowedPictureIsRefusedBeforeItIsDecoded() async {
        let (cache, _) = cache(ClaimedSizeJPEG.make(width: 4_097, height: 100))
        await #expect(throws: GymPhotoCacheError.tooManyPixels) { _ = try await cache.image(from: url) }
        let (tall, _) = self.cache(ClaimedSizeJPEG.make(width: 100, height: 4_097))
        await #expect(throws: GymPhotoCacheError.tooManyPixels) { _ = try await tall.image(from: url) }
    }

    @Test func theSavePathRefusesTooWhenGivenBytesDirectly() {
        let (cache, _) = cache(Data())
        #expect(throws: GymPhotoCacheError.tooManyPixels) {
            _ = try cache.save(ClaimedSizeJPEG.make(width: 30_000, height: 30_000))
        }
    }

    @Test func theFilesOfAnAccountsOwnBucketAreRefusedAtTheThumbnailStepToo() {
        #expect(throws: GymPhotoError.self) {
            _ = try GymPhotoProcessor.thumbnail(ofCleaned: ClaimedSizeJPEG.make(width: 30_000, height: 30_000))
        }
    }

    @Test func aPictureAtTheEdgeIsNotTooLarge() {
        let (cache, _) = cache(Data())
        do {
            _ = try cache.save(ClaimedSizeJPEG.make(width: 4_096, height: 4_096))
        } catch GymPhotoCacheError.tooManyPixels {
            Issue.record("4096 a side is allowed")
        } catch {
            // The pixels aren't really there, so the thumbnail step may fail: only the size check is under test.
        }
    }

    @Test func aRealPictureShownIsDecodedAtADownsampledSize() async throws {
        let (cache, _) = cache(GymPhotoFixture.jpegData())
        let image = try await cache.image(from: url)
        #expect(max(image.size.width * image.scale, image.size.height * image.scale) <= CGFloat(GymPhotoCache.shownLongEdge))
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
