import Foundation
@testable import GymSync

/// One canned answer from the stub API.
struct StubAnswer: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    static func json(_ status: Int, _ text: String, headers: [String: String] = [:]) -> StubAnswer {
        StubAnswer(status: status, headers: ["Content-Type": "application/json"].merging(headers) { _, new in new },
                   body: Data(text.utf8))
    }
}

/// A request as the stub saw it. URLSession hands a protocol the body as a stream; it is read here.
struct SeenRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?

    var path: String { url.path() }

    var query: [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    func json() throws -> Any { try JSONSerialization.jsonObject(with: body ?? Data()) }
}

/// Answers URLSession requests in tests. Each `StubServer` registers under a host of its own, so tests running in
/// parallel never see each other's requests.
final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (SeenRequest) throws -> StubAnswer

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(host: String, _ handler: @escaping Handler) { lock.withLock { handlers[host] = handler } }
    static func unregister(host: String) { _ = lock.withLock { handlers.removeValue(forKey: host) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let handler = Self.lock.withLock({ Self.handlers[url.host() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let seen = SeenRequest(method: request.httpMethod ?? "GET", url: url,
                               headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
        do {
            let answer = try handler(seen)
            guard let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                                 headerFields: answer.headers)
            else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: answer.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A fake API for one test: a host of its own, the requests it saw, and clients pointed at it. Keep it alive for as
/// long as its clients are used (its `deinit` unregisters the host).
final class StubServer: @unchecked Sendable {
    let host = "api-\(UUID().uuidString.lowercased()).test"
    private let lock = NSLock()
    private var seen: [SeenRequest] = []

    init(_ handler: @escaping StubURLProtocol.Handler) {
        StubURLProtocol.register(host: host) { [weak self] request in
            self?.record(request)
            return try handler(request)
        }
    }

    deinit { StubURLProtocol.unregister(host: host) }

    var baseURL: URL { URL(string: "http://\(host)")! }
    var requests: [SeenRequest] { lock.withLock { seen } }

    func client(sessions: any SessionStore = InMemorySessionStore()) -> ApiClient {
        ApiClient(baseURL: baseURL, sessions: sessions,
                  urlSession: ApiClient.makeURLSession(protocolClasses: [StubURLProtocol.self]))
    }

    private func record(_ request: SeenRequest) { lock.withLock { seen.append(request) } }
}
