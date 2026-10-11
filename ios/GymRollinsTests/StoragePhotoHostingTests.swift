import Foundation
import GymCore
import Synchronization
import Testing
import UIKit
@testable import GymRollins

/// Serves canned replies per URL host and records requests, so each test (with its own host) is independent of the
/// other suites running in parallel. No network is ever touched.
final class HostStubURLProtocol: URLProtocol {
    struct Reply: Sendable { let status: Int; let body: Data }
    private static let state = Mutex<(replies: [String: @Sendable (URL) -> Reply?], requests: [String: [URL]])>(([:], [:]))

    static func serve(host: String, _ reply: @escaping @Sendable (URL) -> Reply?) {
        state.withLock { $0.replies[host] = reply; $0.requests[host] = [] }
    }
    static func requests(host: String) -> [URL] { state.withLock { $0.requests[host] ?? [] } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HostStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        let reply = Self.state.withLock { state -> Reply? in
            state.requests[host, default: []].append(url)
            return state.replies[host]?(url)
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum PhotoTestData {
    static func jpeg(width: CGFloat = 30, height: CGFloat = 20) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .jpegData(withCompressionQuality: 0.8) {
                UIColor.orange.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
    }

    static func manifest(_ photos: [String: Int], rev: [String: String] = [:], version: Int = 1) -> Data {
        let object: [String: Any] = ["version": version, "updatedAt": "2026-09-29T10:00:00Z", "photos": photos, "rev": rev]
        return try! JSONSerialization.data(withJSONObject: object) // swiftlint:disable:this force_try
    }

    static func uniqueHost() -> String { "t\(UUID().uuidString.prefix(8).lowercased()).supabase.test" }

    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("photo-hosting-\(UUID().uuidString)")
    }

    static func exercise(_ id: String, image: String? = nil) -> Exercise {
        Exercise(id: id, name: "exercise \(id)", bodyPart: "chest", equipment: "barbell", target: "pectorals",
                 image: image, gif: nil)
    }
}

// MARK: - URL policy (https-only in production, DEBUG-only http to the local stack)

@Suite struct PhotoURLPolicyTests {
    @Test func httpsOnlyRejectsEveryPlainHTTPURL() {
        let policy = PhotoURLPolicy.httpsOnly
        #expect(policy.allows(URL(string: "https://abc.supabase.co/x.jpg")!))
        #expect(!policy.allows(URL(string: "http://127.0.0.1:55421/x.jpg")!))
        #expect(!policy.allows(URL(string: "http://localhost:55421/x.jpg")!))
        #expect(!policy.allows(URL(string: "ftp://abc.supabase.co/x.jpg")!))
        #expect(!policy.allows(URL(fileURLWithPath: "/tmp/x.jpg")))
    }

    @Test func debugPolicyAllowsHTTPOnlyToLoopbackAndALocalSupabaseHost() {
        let loopback = PhotoURLPolicy.debugLocal(supabaseURL: URL(string: "http://127.0.0.1:55421"))
        #expect(loopback.allows(URL(string: "http://127.0.0.1:55421/a.jpg")!))
        #expect(loopback.allows(URL(string: "http://localhost:55421/a.jpg")!))
        #expect(!loopback.allows(URL(string: "http://cdn.example.com/a.jpg")!))
        #expect(!loopback.allows(URL(string: "http://192.168.1.20:55421/a.jpg")!), "LAN hosts only when configured")

        let lan = PhotoURLPolicy.debugLocal(supabaseURL: URL(string: "http://192.168.1.20:55421"))
        #expect(lan.allows(URL(string: "http://192.168.1.20:55421/a.jpg")!))

        let publicHTTP = PhotoURLPolicy.debugLocal(supabaseURL: URL(string: "http://abc.supabase.co"))
        #expect(!publicHTTP.allows(URL(string: "http://abc.supabase.co/a.jpg")!), "a public host never gets http")
    }

    @Test func thisDebugBuildUsesTheDebugPolicy() {
        let url = URL(string: "http://127.0.0.1:55421")
        #expect(PhotoURLPolicy.forBuild(supabaseURL: url) == PhotoURLPolicy.debugLocal(supabaseURL: url))
    }

    @Test(arguments: [
        ("127.0.0.1", true), ("127.1.2.3", true), ("localhost", true), ("::1", true), ("[::1]", true),
        ("10.0.0.5", true), ("192.168.0.9", true), ("172.16.0.1", true), ("172.31.255.255", true),
        ("169.254.1.1", true), ("macbook.local", true),
        ("172.32.0.1", false), ("192.169.0.1", false), ("8.8.8.8", false), ("abc.supabase.co", false),
        ("127.0.0.1.evil.com", false), (".local", false), ("300.1.1.1", false), ("10.0.0", false)
    ])
    func localDevHostDetection(host: String, expected: Bool) {
        #expect(PhotoURLPolicy.isLocalDevHost(host) == expected)
    }

    @Test func storeFetchesLocalHTTPOnlyWithTheDebugPolicy() async throws {
        let body = PhotoTestData.jpeg()
        HostStubURLProtocol.serve(host: "127.0.0.1") { _ in .init(status: 200, body: body) }
        let url = URL(string: "http://127.0.0.1:55421/storage/v1/object/public/exercise-photos/own-0001-0.jpg")!
        let strict = ExercisePhotoStore(session: HostStubURLProtocol.session(), directory: PhotoTestData.tempDir())
        await #expect(throws: ExercisePhotoError.insecureURL) { try await strict.data(for: url) }

        let debug = ExercisePhotoStore(session: HostStubURLProtocol.session(), directory: PhotoTestData.tempDir(),
                                       policy: .debugLocal(supabaseURL: URL(string: "http://127.0.0.1:55421")))
        #expect(try await debug.data(for: url) == body)
        await #expect(throws: ExercisePhotoError.insecureURL) {
            try await debug.data(for: URL(string: "http://cdn.example.com/a.jpg")!)
        }
    }
}

// MARK: - Config switch

@Suite struct PhotoHostingConfigTests {
    private let anon = "anon-key"

    @Test func settingDefaultsToBundle() {
        #expect(PhotoHosting(rawSetting: nil) == .bundle)
        #expect(PhotoHosting(rawSetting: "") == .bundle)
        #expect(PhotoHosting(rawSetting: "cdn") == .bundle)
        #expect(PhotoHosting(rawSetting: "bundle") == .bundle)
        #expect(PhotoHosting(rawSetting: " Storage ") == .storage)
    }

    @Test func resolvesFromInfoPlist() {
        let info: [String: Any] = ["PHOTO_HOSTING": "storage", "SUPABASE_URL": "https://abc.supabase.co",
                                   "SUPABASE_ANON_KEY": anon]
        let config = PhotoHostingConfig.resolve(info: info, environment: [:])
        #expect(config == PhotoHostingConfig(hosting: .storage, supabaseURL: URL(string: "https://abc.supabase.co")))
        #expect(PhotoHostingConfig.resolve(info: [:], environment: [:]) == PhotoHostingConfig(hosting: .bundle, supabaseURL: nil))
    }

    @Test func debugEnvironmentOverridesInfoPlist() {
        let info: [String: Any] = ["PHOTO_HOSTING": "bundle", "SUPABASE_URL": "https://abc.supabase.co",
                                   "SUPABASE_ANON_KEY": anon]
        let env = ["PHOTO_HOSTING": "storage", "SUPABASE_URL": "http://127.0.0.1:55421", "SUPABASE_ANON_KEY": anon]
        let config = PhotoHostingConfig.resolve(info: info, environment: env)
        #expect(config == PhotoHostingConfig(hosting: .storage, supabaseURL: URL(string: "http://127.0.0.1:55421")))
    }
}

// MARK: - Manifest

@Suite struct StoragePhotoManifestTests {
    @Test func parsesFrameCountsAndRevisions() throws {
        let manifest = try StoragePhotoManifest(data: PhotoTestData.manifest(["0453": 2, "0227": 1],
                                                                             rev: ["0453": "ab12cd34ef56"]))
        #expect(manifest.photos == ["0453": 2, "0227": 1])
        #expect(manifest.rev == ["0453": "ab12cd34ef56"])
    }

    @Test func dropsMalformedEntriesButKeepsTheRest() throws {
        let manifest = try StoragePhotoManifest(data: PhotoTestData.manifest(
            ["0453": 2, "../x": 2, "12a": 1, "0001": 0, "0002": 99, "": 1],
            rev: ["0453": "not-hex!", "0001": "abc"]))
        #expect(manifest.photos == ["0453": 2])
        #expect(manifest.rev == ["0001": "abc"])
    }

    @Test func rejectsUnknownVersionsGarbageAndOversizedFiles() {
        #expect(throws: StoragePhotoManifest.ParseError.unsupportedVersion(2)) {
            try StoragePhotoManifest(data: PhotoTestData.manifest(["0453": 2], version: 2))
        }
        #expect(throws: (any Error).self) { try StoragePhotoManifest(data: Data("<html>".utf8)) }
        #expect(throws: StoragePhotoManifest.ParseError.tooLarge) {
            try StoragePhotoManifest(data: Data(count: StoragePhotoManifest.maxBytes + 1))
        }
    }
}

// MARK: - Provider + URL building

@Suite struct SupabaseStoragePhotoProviderTests {
    @Test func buildsPublicObjectURLsWithTheRevision() {
        let provider = SupabaseStoragePhotoProvider(
            supabaseURL: URL(string: "http://127.0.0.1:55421")!,
            manifest: StoragePhotoManifest(photos: ["0453": 2], rev: ["0453": "ab12"]))
        let media = provider.media(for: PhotoTestData.exercise("0453"))
        #expect(media?.source == .own)
        #expect(media?.photos.map(\.absoluteString) == [
            "http://127.0.0.1:55421/storage/v1/object/public/exercise-photos/own-0453-0.jpg?v=ab12",
            "http://127.0.0.1:55421/storage/v1/object/public/exercise-photos/own-0453-1.jpg?v=ab12"
        ])
    }

    @Test func trailingSlashAndNoRevision() {
        let provider = SupabaseStoragePhotoProvider(supabaseURL: URL(string: "https://abc.supabase.co/")!,
                                                    manifest: StoragePhotoManifest(photos: ["0227": 1]))
        #expect(provider.media(for: PhotoTestData.exercise("0227"))?.photos.map(\.absoluteString) ==
            ["https://abc.supabase.co/storage/v1/object/public/exercise-photos/own-0227-0.jpg"])
        #expect(SupabaseStoragePhotoProvider.manifestURL(supabaseURL: URL(string: "https://abc.supabase.co/")!)
            .absoluteString == "https://abc.supabase.co/storage/v1/object/public/exercise-photos/manifest.json")
    }

    @Test func noManifestOrUnlistedExerciseMeansNoMedia() {
        let empty = SupabaseStoragePhotoProvider(supabaseURL: URL(string: "https://abc.supabase.co")!)
        #expect(empty.media(for: PhotoTestData.exercise("0453")) == nil)
        empty.apply(StoragePhotoManifest(photos: ["0453": 1]))
        #expect(empty.media(for: PhotoTestData.exercise("0453"))?.photos.count == 1)
        #expect(empty.media(for: PhotoTestData.exercise("0001")) == nil)
        #expect(empty.media(for: PhotoTestData.exercise("custom-1")) == nil)
    }

    /// record URLs -> Storage -> bundled own photos -> free-exercise-db -> (nil) illustration.
    @Test func providerOrder() throws {
        let storage = SupabaseStoragePhotoProvider(supabaseURL: URL(string: "https://abc.supabase.co")!,
                                                   manifest: StoragePhotoManifest(photos: ["0453": 2, "0001": 1]))
        let bundled = BundledOwnPhotoProvider(files: [
            URL(fileURLWithPath: "/app/own-0453-0.jpg"), URL(fileURLWithPath: "/app/own-0002-0.jpg")
        ])
        let fedb = try FreeExerciseDBPhotoProvider(data: Data("""
        {"baseURL":"https://cdn.example.com/fedb/","photos":{"0003":["A/0.jpg"],"0453":["B/0.jpg"]}}
        """.utf8))
        let chain = ChainedMediaProvider([ExerciseRecordMediaProvider(), storage, bundled, fedb])

        let record = chain.media(for: PhotoTestData.exercise("0453", image: "https://media.example.com/0453.jpg"))
        #expect(record?.photos.first?.host() == "media.example.com", "record URLs win")
        #expect(chain.media(for: PhotoTestData.exercise("0453"))?.photos.first?.host() == "abc.supabase.co",
                "Storage wins over the bundled copy")
        #expect(chain.media(for: PhotoTestData.exercise("0002"))?.photos.first?.isFileURL == true,
                "bundled photos when Storage has none")
        #expect(chain.media(for: PhotoTestData.exercise("0003"))?.source == .freeExerciseDB)
        #expect(chain.media(for: PhotoTestData.exercise("0004")) == nil, "illustration")
    }
}

// MARK: - Manifest loading, caching and failure

@Suite struct StoragePhotoManifestLoaderTests {
    private func loader(host: String, cache: URL, scheme: String = "https",
                        policy: PhotoURLPolicy = .httpsOnly) -> StoragePhotoManifestLoader {
        StoragePhotoManifestLoader(
            manifestURL: SupabaseStoragePhotoProvider.manifestURL(supabaseURL: URL(string: "\(scheme)://\(host)")!),
            cacheDirectory: cache, policy: policy, session: HostStubURLProtocol.session())
    }

    @Test func refreshCachesTheManifestForTheNextLaunch() async {
        let host = PhotoTestData.uniqueHost()
        let cache = PhotoTestData.tempDir()
        HostStubURLProtocol.serve(host: host) { _ in .init(status: 200, body: PhotoTestData.manifest(["0453": 2])) }
        let first = loader(host: host, cache: cache)
        #expect(first.cached() == nil)
        #expect(await first.refresh()?.photos == ["0453": 2])
        #expect(HostStubURLProtocol.requests(host: host).map(\.lastPathComponent) == ["manifest.json"])

        HostStubURLProtocol.serve(host: host) { _ in nil } // offline next launch
        #expect(loader(host: host, cache: cache).cached()?.photos == ["0453": 2])
    }

    @Test(arguments: [500, 404])
    func httpErrorsKeepTheCachedCopy(status: Int) async {
        let host = PhotoTestData.uniqueHost()
        let cache = PhotoTestData.tempDir()
        HostStubURLProtocol.serve(host: host) { _ in .init(status: 200, body: PhotoTestData.manifest(["0453": 2])) }
        _ = await loader(host: host, cache: cache).refresh()
        HostStubURLProtocol.serve(host: host) { _ in .init(status: status, body: Data("{}".utf8)) }
        let again = loader(host: host, cache: cache)
        #expect(await again.refresh() == nil)
        #expect(again.cached()?.photos == ["0453": 2])
    }

    @Test func garbageOrOfflineKeepsTheCachedCopy() async {
        let host = PhotoTestData.uniqueHost()
        let cache = PhotoTestData.tempDir()
        HostStubURLProtocol.serve(host: host) { _ in .init(status: 200, body: PhotoTestData.manifest(["0001": 1])) }
        _ = await loader(host: host, cache: cache).refresh()
        HostStubURLProtocol.serve(host: host) { _ in .init(status: 200, body: Data("<html>captive</html>".utf8)) }
        #expect(await loader(host: host, cache: cache).refresh() == nil)
        HostStubURLProtocol.serve(host: host) { _ in nil }
        #expect(await loader(host: host, cache: cache).refresh() == nil)
        #expect(loader(host: host, cache: cache).cached()?.photos == ["0001": 1])
    }

    @Test func anUnwritableCacheStillUsesTheDownloadedManifest() async throws {
        let host = PhotoTestData.uniqueHost()
        HostStubURLProtocol.serve(host: host) { _ in .init(status: 200, body: PhotoTestData.manifest(["0453": 2])) }
        // A plain file where the cache directory should be: creating the directory / writing the copy fails.
        let blocker = PhotoTestData.tempDir()
        try Data("x".utf8).write(to: blocker)
        #expect(await loader(host: host, cache: blocker).refresh()?.photos == ["0453": 2])
    }

    @Test func disallowedManifestURLIsNeverRequested() async {
        let host = PhotoTestData.uniqueHost()
        HostStubURLProtocol.serve(host: host) { _ in .init(status: 200, body: PhotoTestData.manifest(["0001": 1])) }
        let insecure = loader(host: host, cache: PhotoTestData.tempDir(), scheme: "http")
        #expect(await insecure.refresh() == nil)
        #expect(HostStubURLProtocol.requests(host: host).isEmpty)
    }

    @Test func startServesTheCachedManifestAtOnceThenTheFreshOne() async {
        let host = PhotoTestData.uniqueHost()
        let cache = PhotoTestData.tempDir()
        HostStubURLProtocol.serve(host: host) { _ in .init(status: 200, body: PhotoTestData.manifest(["0001": 1])) }
        _ = await loader(host: host, cache: cache).refresh()
        HostStubURLProtocol.serve(host: host) { _ in .init(status: 200, body: PhotoTestData.manifest(["0001": 1, "0002": 2])) }

        let (provider, refresh) = SupabaseStoragePhotoProvider.start(
            supabaseURL: URL(string: "https://\(host)")!, loader: loader(host: host, cache: cache))
        #expect(provider.currentManifest?.photos == ["0001": 1], "stale copy first")
        await refresh.value
        #expect(provider.currentManifest?.photos == ["0001": 1, "0002": 2], "then revalidated")
        #expect(HostStubURLProtocol.requests(host: host).count == 1, "one manifest fetch per launch")
    }

    @Test func failedFirstFetchFallsBackToBundledAndFreePhotos() async throws {
        let host = PhotoTestData.uniqueHost()
        HostStubURLProtocol.serve(host: host) { _ in nil }
        let (storage, refresh) = SupabaseStoragePhotoProvider.start(
            supabaseURL: URL(string: "https://\(host)")!, loader: loader(host: host, cache: PhotoTestData.tempDir()))
        await refresh.value
        let bundled = BundledOwnPhotoProvider(files: [URL(fileURLWithPath: "/app/own-0453-0.jpg")])
        let fedb = try FreeExerciseDBPhotoProvider(data: Data("""
        {"baseURL":"https://cdn.example.com/fedb/","photos":{"0003":["A/0.jpg"]}}
        """.utf8))
        let chain = ChainedMediaProvider([ExerciseRecordMediaProvider(), storage, bundled, fedb])
        #expect(chain.media(for: PhotoTestData.exercise("0453"))?.photos.first?.isFileURL == true)
        #expect(chain.media(for: PhotoTestData.exercise("0003"))?.source == .freeExerciseDB)
    }
}

// MARK: - Wiring (config switch -> providers)

@Suite struct ExerciseMediaServiceHostingTests {
    private let https = URL(string: "https://abc.supabase.co")!

    @Test func bundleModeHasNoStorageProvider() {
        let config = PhotoHostingConfig(hosting: .bundle, supabaseURL: https)
        #expect(ExerciseMediaService.storageProvider(config: config, policy: .httpsOnly) == nil)
    }

    @Test func storageModeNeedsASupabaseURLTheBuildMayFetch() {
        #expect(ExerciseMediaService.storageProvider(
            config: PhotoHostingConfig(hosting: .storage, supabaseURL: nil), policy: .httpsOnly) == nil)
        #expect(ExerciseMediaService.storageProvider(
            config: PhotoHostingConfig(hosting: .storage, supabaseURL: URL(string: "http://127.0.0.1:55421")),
            policy: .httpsOnly) == nil, "Release policy: never plain http, not even to the local stack")
    }

    @Test func storageModeBuildsTheProviderAndRefreshesTheManifest() async {
        let host = PhotoTestData.uniqueHost()
        HostStubURLProtocol.serve(host: host) { _ in .init(status: 200, body: PhotoTestData.manifest(["0453": 2])) }
        let config = PhotoHostingConfig(hosting: .storage, supabaseURL: URL(string: "https://\(host)"))
        let started = ExerciseMediaService.storageProvider(config: config, policy: .httpsOnly) { url in
            StoragePhotoManifestLoader(manifestURL: url, cacheDirectory: PhotoTestData.tempDir(), policy: .httpsOnly,
                                       session: HostStubURLProtocol.session())
        }
        await started?.refresh.value
        #expect(started?.provider.media(for: PhotoTestData.exercise("0453"))?.photos.count == 2)
    }

    @Test func uiTestingStaysHermeticEvenWithStorageConfigured() {
        let info: [String: Any] = ["PHOTO_HOSTING": "storage", "SUPABASE_URL": "https://abc.supabase.co",
                                   "SUPABASE_ANON_KEY": "anon"]
        let service = ExerciseMediaService.make(options: LaunchOptions(arguments: ["-uiTesting"], environment: [:]),
                                                info: info)
        #expect(service.provider.media(for: PhotoTestData.exercise("0453")) == nil)
    }
}
