import Foundation

public enum ApiConfigError: Error, Equatable, Sendable {
    case missing
    case invalidURL(String)
}

/// Where the GymRollins API lives. The app reads Info.plist key `API_URL`, filled from `ios/Config/Base.xcconfig` (the
/// local Worker, `http://127.0.0.1:8787`) or a `Local.xcconfig` override once a Worker is deployed. Only an origin is
/// accepted (scheme, host and port), so `origin` names one API exactly: the server move compares it.
public struct ApiConfig: Sendable, Equatable {
    public static let urlKey = "API_URL"

    /// `scheme://host[:port]`: lowercased, with no path and no default port.
    public let baseURL: URL

    /// Validates an Info.plist-style dictionary.
    public init(info: [String: Any]) throws {
        guard let raw = (info[Self.urlKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { throw ApiConfigError.missing }
        guard let parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/"
        else { throw ApiConfigError.invalidURL(raw) }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = parts.port == (scheme == "https" ? 443 : 80) ? nil : parts.port
        guard let url = origin.url else { throw ApiConfigError.invalidURL(raw) }
        baseURL = url
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        try self.init(info: environment)
    }

    public static func fromBundle(_ bundle: Bundle = .main) throws -> ApiConfig {
        try ApiConfig(info: bundle.infoDictionary ?? [:])
    }

    /// What `SyncStore.syncedServer` keeps: the same text for the same API, different for any other.
    public var origin: String { baseURL.absoluteString }

    public func makeClient(sessions: any SessionStore) -> ApiClient {
        ApiClient(baseURL: baseURL, sessions: sessions)
    }
}
