import Foundation

/// The signed-in session as the phone keeps it: Better Auth's bearer token, and whose it is, so a launch without
/// network still knows who is signed in.
public struct StoredSession: Codable, Equatable, Sendable {
    public let token: String
    public let userId: UUID
    public let email: String?

    public init(token: String, userId: UUID, email: String?) {
        self.token = token
        self.userId = userId
        self.email = email
    }
}

/// Where the session lives: the Keychain in the app (`KeychainSessionStore`), memory in tests.
public protocol SessionStore: Sendable {
    func load() -> StoredSession?
    func save(_ session: StoredSession) throws
    /// Forgets the session. With a token, only while the store still holds that one, so a 401 to an older request
    /// can't end a session signed in since.
    func clear(ifToken token: String?)
}

extension SessionStore {
    public func clear() { clear(ifToken: nil) }
}

/// A process-local session store for tests and previews.
public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: StoredSession?

    public init(_ session: StoredSession? = nil) { self.session = session }

    public func load() -> StoredSession? { lock.withLock { session } }

    public func save(_ session: StoredSession) throws { lock.withLock { self.session = session } }

    public func clear(ifToken token: String?) {
        lock.withLock {
            if token == nil || session?.token == token { session = nil }
        }
    }
}
