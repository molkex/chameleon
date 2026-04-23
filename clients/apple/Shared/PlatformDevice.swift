import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Cross-platform device metadata for API headers and registration.
/// On iOS we use UIKit's `identifierForVendor` (stable per vendor, wiped on
/// app uninstall). On macOS — a UUID saved in UserDefaults on first launch.
/// Both are non-sensitive and Apple-compliant.
enum PlatformDevice {

    /// Stable per-install identifier. UUID string.
    static var identifier: String {
        #if os(iOS)
        if let vendorID = UIDevice.current.identifierForVendor?.uuidString {
            return vendorID
        }
        return fallbackIdentifier()
        #else
        return fallbackIdentifier()
        #endif
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

    private static let fallbackKey = "com.madfrog.vpn.deviceIdentifier"

    private static func fallbackIdentifier() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: fallbackKey) {
            return existing
        }
        let new = UUID().uuidString
        defaults.set(new, forKey: fallbackKey)
        return new
    }
}

