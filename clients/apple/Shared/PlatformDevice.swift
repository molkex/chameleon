import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Cross-platform device metadata for API headers and registration.
/// The device identifier is the backend account key for anonymous users, so it
/// must be DURABLE across app delete+reinstall. See `identifier` below.
/// Non-sensitive and Apple-compliant.
enum PlatformDevice {

    private static let deviceIdentifierKey = "deviceIdentifier"
    private static let seedLock = NSLock()

    /// Stable per-install identifier (UUID string), durable across app
    /// delete+reinstall.
    ///
    /// ACCT-IDENTITY (2026-06-01): this previously returned UIKit's
    /// `identifierForVendor` directly. IFV RESETS when the user deletes all of
    /// the vendor's apps and reinstalls — which orphaned the backend account
    /// (new device_id ⇒ a brand-new anonymous user, losing the paid identity).
    /// We now persist the id in the Keychain, which survives delete/reinstall
    /// (Apple's own identifierForVendor docs recommend exactly this). On the
    /// first run of this build we SEED the Keychain — in priority order — from
    /// (1) the current IFV (existing iOS installs are keyed on it) or (2) the
    /// legacy UserDefaults UUID (existing macOS installs), so nobody is
    /// orphaned on upgrade. Thereafter the Keychain value is authoritative.
    /// Only the main app reads this (never the extension), so no shared
    /// keychain access group is needed.
    static var identifier: String {
        seedLock.lock()
        defer { seedLock.unlock() }
        if let stored = KeychainHelper.load(key: deviceIdentifierKey) {
            return stored
        }
        let seed = vendorIdentifier() ?? legacyUserDefaultsIdentifier() ?? UUID().uuidString
        KeychainHelper.save(key: deviceIdentifierKey, value: seed)
        return seed
    }

    /// iOS vendor id, used only as the first-run migration seed. nil on macOS.
    private static func vendorIdentifier() -> String? {
        #if os(iOS)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }

    /// Pre-existing UserDefaults UUID (the old macOS/iOS fallback). Read-only —
    /// does NOT create one, so it only contributes a seed for existing installs.
    private static func legacyUserDefaultsIdentifier() -> String? {
        UserDefaults.standard.string(forKey: fallbackKey)
    }

    /// Version of the host OS, "17.4.1" on iOS or "14.5.0" on macOS.
    static var systemVersion: String {
        #if os(iOS)
        return UIDevice.current.systemVersion
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    /// Hardware model identifier, e.g. "iPhone17,1" / "Mac15,3" (utsname.machine).
    /// Used in the support-chat diagnostic snapshot — the marketing name isn't
    /// available without a lookup table, but the raw model is enough for triage.
    static var hardwareModel: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let model = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return model.isEmpty ? "unknown" : model
    }

    /// Legacy UserDefaults key from the pre-Keychain identifier scheme. Kept
    /// read-only as a migration seed source (see legacyUserDefaultsIdentifier).
    private static let fallbackKey = "com.madfrog.vpn.deviceIdentifier"
}

