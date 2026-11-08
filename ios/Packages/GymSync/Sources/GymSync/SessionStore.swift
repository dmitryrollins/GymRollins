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

/// A session printed, dumped or put in a log line shows `<redacted>` for its token.
extension StoredSession: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "StoredSession(token: <redacted>, userId: \(userId), email: \(email.map { "\"\($0)\"" } ?? "nil"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["token": "<redacted>", "userId": userId, "email": email as Any], displayStyle: .struct)
    }
}

/// Where the session lives: the Keychain in the app (`KeychainSessionStore`), memory in tests.
public protocol SessionStore: Sendable {
    func load() -> StoredSession?
    func save(_ session: StoredSession) throws
    /// Forgets the session. With a token, only while the store still holds that one, so a 401 to an older request
    /// can't end a session signed in since. True when a session was forgotten.
    @discardableResult func clear(ifToken token: String?) -> Bool
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

    @discardableResult public func clear(ifToken token: String?) -> Bool {
        lock.withLock {
            guard let held = session, token == nil || held.token == token else { return false }
            session = nil
            return true
        }
    }
}
