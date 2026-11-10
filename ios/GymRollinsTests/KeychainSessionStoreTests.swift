import Foundation
import GymSync
import Security
import Testing

/// The app's session in the Keychain: saved, read back, replaced, and cleared only for the token a 401 answered.
@Suite struct KeychainSessionStoreTests {
    private let store = KeychainSessionStore(service: "com.rollins.gymrollins.test-session-\(UUID().uuidString)")

    @Test func savesReadsReplacesAndClears() throws {
        defer { store.clear() }
        #expect(store.load() == nil)
        let first = StoredSession(token: "t1.sig", userId: UUID(), email: "a@test.local")
        try store.save(first)
        #expect(store.load() == first)
        let second = StoredSession(token: "t2.sig", userId: first.userId, email: nil)
        try store.save(second)
        #expect(store.load() == second)
        #expect(!store.clear(ifToken: "t1.sig"))
        #expect(store.load() == second, "a 401 to the older token leaves the newer session")
        #expect(store.clear(ifToken: "t2.sig"))
        #expect(store.load() == nil)
        #expect(!store.clear(ifToken: nil), "nothing left to forget")
    }

    @Test func twoServicesDontShareASession() throws {
        let other = KeychainSessionStore(service: "com.rollins.gymrollins.test-session-\(UUID().uuidString)")
        defer {
            store.clear()
            other.clear()
        }
        try store.save(StoredSession(token: "mine", userId: UUID(), email: nil))
        #expect(store.load() != nil)
        #expect(other.load() == nil)
    }

    @Test func theItemStaysOnThisDeviceAfterFirstUnlock() throws {
        let service = "com.rollins.gymrollins.test-attributes-\(UUID().uuidString)"
        let store = KeychainSessionStore(service: service)
        defer { store.clear() }
        try store.save(StoredSession(token: "t", userId: UUID(), email: nil))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "session", kSecReturnAttributes as String: true,
                                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let attributes = try #require(result as? [String: Any])
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        let sync = attributes[kSecAttrSynchronizable as String]
        #expect(sync == nil || (sync as? Bool) == false || (sync as? Int) == 0, "never iCloud Keychain")
    }

    @Test func savingOverAnExistingSessionReplacesItInPlace() throws {
        defer { store.clear() }
        let first = StoredSession(token: "t1", userId: UUID(), email: nil)
        try store.save(first)
        try store.save(StoredSession(token: "t2", userId: first.userId, email: nil))
        #expect(store.load()?.token == "t2", "replaced in place")
    }
}
