import Foundation

/// The GymRollins API (the Worker in `server/`) over URLSession. Requests carry the stored session token as
/// `Authorization: Bearer` and JSON bodies; an answer outside 2xx is thrown as `ApiError`, a network failure as
/// `URLError`. The session never sends or keeps cookies (the API takes only the bearer, spec section 7) and has no
/// URL cache, so one account's answers can't be served to another. No redirect is followed, so the bearer can't go
/// anywhere else: the API never redirects, and a 3xx is thrown as an `ApiError` like any answer outside 2xx.
///
/// A 401 to a request that carried the stored token means the server ended that session (signed out elsewhere, expired,
/// account deleted): the token is forgotten and `unauthorized` yields, which `AuthService` turns into a sign-out. The
/// local data stays. When the store already holds a newer session (a sign-in finished while the request was on the
/// wire), nothing is forgotten and nothing yields.
public struct ApiClient: Sendable {
    /// Which token a request carries. Printed, dumped or logged, a given token shows as `<redacted>`.
    enum Bearer: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        case stored
        case anonymous
        case token(String)

        var description: String {
            switch self {
            case .stored: "stored"
            case .anonymous: "anonymous"
            case .token: "token(<redacted>)"
            }
        }

        var debugDescription: String { description }

        var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }
    }

    /// The API's origin, e.g. `http://127.0.0.1:8787` (`ApiConfig.baseURL`).
    public let baseURL: URL
    let sessions: any SessionStore
    private let urlSession: URLSession
    /// One element per 401 that ended the stored session. `AuthService` is its only reader.
    let unauthorized: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation

    public init(baseURL: URL, sessions: any SessionStore, urlSession: URLSession = ApiClient.makeURLSession()) {
        self.baseURL = baseURL
        self.sessions = sessions
        self.urlSession = urlSession
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        unauthorized = stream
        signal = continuation
    }

    /// Ephemeral, with cookies and the URL cache off. Tests put their stub protocol in front.
    public static func makeURLSession(protocolClasses: [AnyClass] = []) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if !protocolClasses.isEmpty {
            configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        }
        return URLSession(configuration: configuration)
    }

    /// The session's settings, for the tests.
    var configuration: URLSessionConfiguration { urlSession.configuration }

    /// `GET`, the answer decoded with `SyncJSON.decoder`.
    func get<Response: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Response {
        let (body, _) = try await data("GET", path, query: query)
        return try SyncJSON.decoder.decode(Response.self, from: body)
    }

    /// `POST` with `payload` encoded by `SyncJSON.encoder`, the answer decoded with `SyncJSON.decoder`.
    func post<Payload: Encodable, Response: Decodable>(_ path: String, _ payload: Payload) async throws -> Response {
        let (body, _) = try await data("POST", path, body: SyncJSON.encoder.encode(payload))
        return try SyncJSON.decoder.decode(Response.self, from: body)
    }

    /// One exchange; the body and response of a 2xx answer.
    func data(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
              bearer: Bearer = .stored) async throws -> (body: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: try url(path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let token: String? = switch bearer {
        case .stored: sessions.load()?.token
        case .anonymous: nil
        case .token(let given): given
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (answer, response) = try await urlSession.data(for: request, delegate: RefusesRedirects.shared)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            // Only when this 401 ended the stored session: a token since replaced leaves the newer one signed in.
            if http.statusCode == 401, case .stored = bearer, let token, sessions.clear(ifToken: token) {
                signal.yield()
            }
            throw ApiError.from(status: http.statusCode, body: answer)
        }
        return (answer, http)
    }

    private func url(_ path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        else { throw URLError(.badURL) }
        if !query.isEmpty {
            components.queryItems = query
            // URLComponents leaves "+" as it is, and a server reads it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }
}

/// Answers every redirect with nil, so URLSession hands back the 3xx instead of following it with the bearer. It is
/// each request's own delegate, so a session passed to `ApiClient.init` refuses redirects too.
final class RefusesRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RefusesRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
