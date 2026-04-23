import Foundation
import Security

/// Minimal Keychain wrapper for storing credentials securely.
/// Uses kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly so the tunnel
/// extension can read values when the device is locked, while preventing
/// the credentials from being included in iCloud Keychain sync or
/// encrypted iCloud backups (the *ThisDeviceOnly* tier).
enum KeychainHelper {
    private static let service = "com.madfrog.vpn"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // Try update first (atomic), fall back to insert. Avoids the
        // delete-then-add race where the PacketTunnel extension could read
        // the key in the gap and get nil — credentials must never blink off
        // while the tunnel is up.
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            // Keychain key names map directly to credential types
            // (mobileAccessToken etc.); never write them to console in
            // Release builds where they'd land in device logs.
            #if DEBUG
            print("[Keychain] update failed: \(updateStatus) for key: \(key)")
            #endif
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            #if DEBUG
            print("[Keychain] add failed: \(addStatus) for key: \(key)")
            #endif
        }
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
