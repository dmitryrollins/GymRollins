import Foundation
import Supabase

public enum SupabaseConfigError: Error, Equatable, Sendable {
    case missing(String)
    case invalidURL(String)
}

/// Where the app's Supabase project lives. The app reads it from Info.plist keys `SUPABASE_URL` /
/// `SUPABASE_ANON_KEY`, filled from `ios/Config/Base.xcconfig` (local stack defaults) or a `Local.xcconfig`
/// override for a cloud build. The anon key is public by design; the service-role key never ships in the app.
public struct SupabaseConfig: Sendable, Equatable {
    public static let urlKey = "SUPABASE_URL"
    public static let anonKeyKey = "SUPABASE_ANON_KEY"

    public let url: URL
    public let anonKey: String

    public init(url: URL, anonKey: String) {
        self.url = url
        self.anonKey = anonKey
    }

    /// Validates an Info.plist-style dictionary.
    public init(info: [String: Any]) throws {
        let rawURL = try Self.value(Self.urlKey, in: info)
        let key = try Self.value(Self.anonKeyKey, in: info)
        guard let url = URL(string: rawURL), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty
        else { throw SupabaseConfigError.invalidURL(rawURL) }
        self.init(url: url, anonKey: key)
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        try self.init(info: environment)
    }

    public static func fromBundle(_ bundle: Bundle = .main) throws -> SupabaseConfig {
        try SupabaseConfig(info: bundle.infoDictionary ?? [:])
    }

    /// A client that keeps its session in `storage` (the Keychain by default, as on device).
    public func makeClient(storage: (any AuthLocalStorage)? = nil) -> SupabaseClient {
        let auth = SupabaseClientOptions.AuthOptions(
            storage: storage ?? AuthClient.Configuration.defaultLocalStorage,
            emitLocalSessionAsInitialSession: true)
        return SupabaseClient(supabaseURL: url, supabaseKey: anonKey, options: SupabaseClientOptions(auth: auth))
    }

    private static func value(_ key: String, in info: [String: Any]) throws -> String {
        guard let raw = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw SupabaseConfigError.missing(key)
        }
        return raw
    }
}

/// A process-local session store for tests and previews (the app uses the Keychain).
public final class InMemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func store(key: String, value: Data) throws {
        lock.withLock { values[key] = value }
    }

    public func retrieve(key: String) throws -> Data? {
        lock.withLock { values[key] }
    }

    public func remove(key: String) throws {
        _ = lock.withLock { values.removeValue(forKey: key) }
    }
}
