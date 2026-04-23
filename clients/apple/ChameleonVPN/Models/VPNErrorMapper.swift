import Foundation
import NetworkExtension

/// Maps raw VPN / NetworkExtension errors into short, human messages we
/// actually want to show the user. Keeps AppState free of stringly logic.
///
/// Every message is intentionally short (fits in a toast) and ends with an
/// actionable hint ("Try another server", "Check Wi-Fi", etc).
enum VPNErrorMapper {
    static func humanMessage(_ error: Error) -> String {
        let ns = error as NSError

        if ns.domain == NEVPNErrorDomain, let code = NEVPNError.Code(rawValue: ns.code) {
            switch code {
            case .configurationInvalid:
                return L10n.Error.configInvalid
            case .configurationDisabled:
                return L10n.Error.configDisabled
            case .connectionFailed:
                return L10n.Error.connectionFailed
            case .configurationStale:
                return L10n.Error.configStale
            case .configurationReadWriteFailed:
                return L10n.Error.rwFailed
            case .configurationUnknown:
                return L10n.Error.configInvalid
            @unknown default:
                break
            }
        }

        let raw = error.localizedDescription.lowercased()

        if raw.contains("permission") || raw.contains("denied") || raw.contains("not permitted") {
            return L10n.Error.permission
        }
        if raw.contains("offline") || raw.contains("network") || raw.contains("internet") || raw.contains("host") {
            return L10n.Error.offline
        }
        if raw.contains("timeout") || raw.contains("timed out") {
            return L10n.Error.serverTimeout
        }

        // Generic fallback — keep the original, but trim common noise prefixes.
        var cleaned = error.localizedDescription
        if cleaned.hasPrefix("The operation couldn't be completed.") {
            cleaned = L10n.Error.generic
        }
        return cleaned
    }

    /// Message when our watchdog fires before the tunnel reaches `.connected`.
    static var watchdogTimeout: String {
        L10n.Error.timeout
    }

    /// Message when permission was never granted (status stuck at .invalid).
    static var permissionMissing: String {
        L10n.Error.permission
    }
}
