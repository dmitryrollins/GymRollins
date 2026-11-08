import Foundation
import os
import Security

/// The Keychain items the old server's sign-in SDK left behind. After the server move their refresh token means nothing
/// here, and a Keychain item travels in backups, so the move deletes them. `service` is that SDK's name for them: the
/// one line scripts/check-old-backend.sh allows to name the old backend, until the owner's phone has moved (then this
/// type and that exception can go).
public enum OldServerKeychain {
    public static let service = "supabase.gotrue.swift"
    private static let log = Logger(subsystem: "com.rollins.gymrollins", category: "keychain")

    /// Deletes every generic-password item under the old SDK's service. Returns the status for tests; anything but
    /// success or "none found" is logged (the status only, never an item's contents).
    @discardableResult public static func forget() -> OSStatus {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            log.error("Could not delete the old server's session, OSStatus \(status, privacy: .public)")
        }
        return status
    }
}
