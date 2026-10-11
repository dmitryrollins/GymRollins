import Foundation
import Synchronization
import Testing
import UIKit
@testable import GymRollins

/// Answers every request from `StubPhotoURLProtocol.responder` and counts requests, so the store's disk cache can be
/// tested without the network.
final class StubPhotoURLProtocol: URLProtocol {
    struct Reply: Sendable { let status: Int; let body: Data; var contentType = "image/jpeg" }
    static let state = Mutex<(requests: [URL], reply: @Sendable (URL) -> Reply?)>(([], { _ in nil }))

    static func reset(_ reply: @escaping @Sendable (URL) -> Reply?) { state.withLock { $0 = ([], reply) } }
    static var requests: [URL] { state.withLock { $0.requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let reply = Self.state.withLock { state -> Reply? in
            state.requests.append(url)
            return state.reply(url)
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": reply.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct ExercisePhotoStoreTests {
    private static func jpeg(_ color: UIColor = .red, side: CGFloat = 40) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).jpegData(withCompressionQuality: 0.8) {
            color.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    private func makeStore(maxBytes: Int = 50_000_000) -> (ExercisePhotoStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photo-store-\(UUID().uuidString)")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubPhotoURLProtocol.self]
        return (ExercisePhotoStore(session: URLSession(configuration: config), directory: dir, maxBytes: maxBytes), dir)
    }

    private let url = URL(string: "https://cdn.example.com/fedb/Bench/0.jpg")!

    @Test func firstLoadFetchesThenServesFromDiskOffline() async throws {
        let body = Self.jpeg()
        StubPhotoURLProtocol.reset { _ in .init(status: 200, body: body) }
        let (store, dir) = makeStore()
        let first = try await store.data(for: url)
        #expect(first == body)
        #expect(StubPhotoURLProtocol.requests.count == 1)

        StubPhotoURLProtocol.reset { _ in nil } // offline from now on
        let again = try await store.data(for: url)
        #expect(again == body)
        #expect(StubPhotoURLProtocol.requests.isEmpty, "a cached photo never touches the network")

        // A new store over the same directory (next launch) still has it.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubPhotoURLProtocol.self]
        let relaunched = ExercisePhotoStore(session: URLSession(configuration: config), directory: dir)
        #expect(try await relaunched.data(for: url) == body)
        #expect(StubPhotoURLProtocol.requests.isEmpty)
    }

    @Test func offlineWithoutCacheThrows() async {
        StubPhotoURLProtocol.reset { _ in nil }
        let (store, _) = makeStore()
        await #expect(throws: (any Error).self) { try await store.data(for: url) }
    }

    @Test func httpErrorsAndNonImagesAreNotCached() async throws {
        StubPhotoURLProtocol.reset { _ in .init(status: 404, body: Data("<html>nope</html>".utf8), contentType: "text/html") }
        let (store, _) = makeStore()
        await #expect(throws: (any Error).self) { try await store.data(for: url) }

        StubPhotoURLProtocol.reset { _ in .init(status: 200, body: Data("not an image".utf8)) }
        await #expect(throws: (any Error).self) { try await store.data(for: url) }

        let body = Self.jpeg()
        StubPhotoURLProtocol.reset { _ in .init(status: 200, body: body) }
        #expect(try await store.data(for: url) == body, "a later good response is fetched, nothing bad was cached")
        #expect(StubPhotoURLProtocol.requests.count == 1)
    }

    @Test func nonHTTPSURLsAreRejectedWithoutARequest() async {
        StubPhotoURLProtocol.reset { _ in .init(status: 200, body: Self.jpeg()) }
        let (store, _) = makeStore()
        await #expect(throws: (any Error).self) {
            try await store.data(for: URL(string: "http://cdn.example.com/a/0.jpg")!)
        }
        #expect(StubPhotoURLProtocol.requests.isEmpty)
    }

    @Test func imageDecodesAndDownsamples() async throws {
        let body = Self.jpeg(side: 400)
        StubPhotoURLProtocol.reset { _ in .init(status: 200, body: body) }
        let (store, _) = makeStore()
        let full = try await store.image(for: url, maxPixelSize: nil)
        #expect(full.size.width * full.scale >= 399)
        let thumb = try await store.image(for: url, maxPixelSize: 100)
        #expect(max(thumb.size.width, thumb.size.height) * thumb.scale <= 100)
        #expect(StubPhotoURLProtocol.requests.count == 1, "both sizes come from one download")
    }

    @Test func evictsOldestFilesOverTheSizeCap() async throws {
        let body = Self.jpeg(side: 200)
        StubPhotoURLProtocol.reset { _ in .init(status: 200, body: body) }
        let (store, dir) = makeStore(maxBytes: body.count * 2 + body.count / 2) // room for two
        let urls = (0..<3).map { URL(string: "https://cdn.example.com/fedb/E\($0)/0.jpg")! }
        for url in urls {
            _ = try await store.data(for: url)
            try await Task.sleep(for: .milliseconds(20)) // distinct modification dates
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path())
        #expect(files.count == 2)

        StubPhotoURLProtocol.reset { _ in nil }
        #expect(try await store.data(for: urls[2]) == body, "newest kept")
        await #expect(throws: (any Error).self, "oldest evicted") { try await store.data(for: urls[0]) }
    }
}
