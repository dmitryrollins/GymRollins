import Foundation

/// The GymRollins API (the Worker in `server/`) over URLSession. Requests carry the stored session token as
/// `Authorization: Bearer` and JSON bodies; an answer outside 2xx is thrown as `ApiError`, a network failure as
/// `URLError`. The session never sends or keeps cookies (the API takes only the bearer, spec section 7) and has no
/// URL cache, so one account's answers can't be served to another.
///
/// A 401 to a request that carried the stored token means the server ended that session (signed out elsewhere, expired,
/// account deleted): the token is forgotten and `unauthorized` yields, which `AuthService` turns into a sign-out. The
/// local data stays.
public struct ApiClient: Sendable {
    /// Which token a request carries.
    enum Bearer: Sendable {
        case stored
        case anonymous
        case token(String)
    }

    /// The API's origin, e.g. `http://127.0.0.1:8787` (`ApiConfig.baseURL`).
    public let baseURL: URL
    let sessions: any SessionStore
    private let urlSession: URLSession
    /// One element per 401 to a request that carried the stored token. `AuthService` is its only reader.
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
        let (answer, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401, case .stored = bearer, let token {
                sessions.clear(ifToken: token)
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
