import Foundation
import Security

/// Minimal Keychain wrapper for storing credentials securely.
///
/// Items live in the **data-protection keychain**, scoped to an explicit
/// access group. This matters on macOS: the *legacy file keychain* (the
/// default when `kSecUseDataProtectionKeychain` is unset) gates each item
/// behind an ACL bound to the creating binary's **code signature /
/// designated requirement**. When the app is re-signed — dev build →
/// TestFlight → App Store, or any provisioning change — the new binary no
/// longer matches that ACL, so `SecItemCopyMatching` returns nil (or pops a
/// "allow access" prompt). That silently looked like a logged-out / fresh
/// account on update and demoted paying users to the trial/onboarding screen
/// (`MadFrogVPNApp` root gate keys off `configStore.username`). See
/// docs/incidents/2026-06-03-macos-keychain-trial-on-update.md.
///
/// The data-protection keychain instead scopes items by **access group**
/// (`<AppIdentifierPrefix>.com.madfrog.vpn.keychain`), which is stable across
/// signatures within the same Team — exactly the durability iOS already had.
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps the tunnel
/// extension able to read while locked, and keeps creds out of iCloud
/// Keychain sync / encrypted backups (the *ThisDeviceOnly* tier).
enum KeychainHelper {
    private static let service = "com.madfrog.vpn"

    /// Explicit, signature-independent access group. Must match the
    /// `keychain-access-groups` entitlement (`$(AppIdentifierPrefix)…`) on
    /// every target. AppIdentifierPrefix == Team ID for this account
    /// (99W3C374T2). Builds before this change wrote to the legacy keychain
    /// (macOS) / the implicit application-identifier group (iOS) instead —
    /// `load(key:)` migrates those forward on first read.
    private static let accessGroup = "99W3C374T2.com.madfrog.vpn.keychain"

    /// Item-identity attributes shared by every query.
    private static func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    /// Canonical location: data-protection keychain + explicit access group.
    private static func dataProtectionQuery(key: String) -> [String: Any] {
        var q = baseQuery(key: key)
        q[kSecUseDataProtectionKeychain as String] = true
        q[kSecAttrAccessGroup as String] = accessGroup
        return q
    }

    /// Pre-migration location: the legacy/default keychain exactly as older
    /// builds wrote it — no data-protection flag, no access group. On macOS
    /// this is the file keychain; on iOS the implicit application-identifier
    /// group. Used only as a migration source by `load(key:)`.
    private static func legacyQuery(key: String) -> [String: Any] {
        baseQuery(key: key)
    }

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query = dataProtectionQuery(key: key)
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
        // 1. Canonical location.
        if let value = read(dataProtectionQuery(key: key)) {
            return value
        }
        // 2. One-time migration: an older build's item still in the legacy
        //    location. Copy it forward into the data-protection keychain (so
        //    the signature-bound ACL never gates us again) and best-effort
        //    remove the stale copy. This keeps already-signed-in users —
        //    iOS and macOS — logged in across this change.
        if let legacy = read(legacyQuery(key: key)) {
            save(key: key, value: legacy)
            SecItemDelete(legacyQuery(key: key) as CFDictionary)
            return legacy
        }
        return nil
    }

    static func delete(key: String) {
        // Clear both locations so an explicit sign-out leaves nothing behind
        // (the legacy copy may still exist if migration never ran for a key).
        SecItemDelete(dataProtectionQuery(key: key) as CFDictionary)
        SecItemDelete(legacyQuery(key: key) as CFDictionary)
    }

    /// Run a copy-data query and decode the result as UTF-8.
    private static func read(_ query: [String: Any]) -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
