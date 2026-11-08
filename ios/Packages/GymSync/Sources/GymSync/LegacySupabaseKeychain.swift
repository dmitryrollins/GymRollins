import Foundation
import os
import Security

/// The Keychain items the Supabase SDK left behind. After the server move the refresh token in them means nothing here,
/// and a Keychain item travels in backups, so the move deletes them.
public enum LegacySupabaseKeychain {
    public static let service = "supabase.gotrue.swift"
    private static let log = Logger(subsystem: "com.rollins.gymrollins", category: "keychain")

    /// Deletes every generic-password item under the Supabase SDK's service. Returns the status for tests; anything but
    /// success or "none found" is logged (the status only, never an item's contents).
    @discardableResult public static func forget() -> OSStatus {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            log.error("Could not delete the old Supabase session, OSStatus \(status, privacy: .public)")
        }
        return status
    }
}
