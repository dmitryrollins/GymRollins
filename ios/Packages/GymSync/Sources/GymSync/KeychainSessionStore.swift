import Foundation
import Security

/// The session in the Keychain: one generic-password item holding `StoredSession` as JSON. It is readable after the
/// first unlock (sync runs in the background) and never leaves this device: no iCloud Keychain, no restore to another
/// phone.
public final class KeychainSessionStore: SessionStore, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()

    /// `service` names the item; tests use their own.
    public init(service: String = "com.rollins.gymrollins.api-session") {
        self.service = service
    }

    public func load() -> StoredSession? {
        lock.withLock { read() }
    }

    public func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        try lock.withLock {
            SecItemDelete(query as CFDictionary)
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }

    @discardableResult public func clear(ifToken token: String?) -> Bool {
        lock.withLock {
            if let token, read()?.token != token { return false }
            return SecItemDelete(query as CFDictionary) == errSecSuccess
        }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "session"]
    }

    private func read() -> StoredSession? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }
}

/// The Keychain refused to store the session.
public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus
}
