import Darwin
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

    /// True iff another VPN extension (not ours) currently owns a tunnel
    /// interface. iOS lets only one NEPacketTunnelProvider be active at a
    /// time — when a third-party VPN is on, our startVPNTunnel fails fast
    /// with a generic .connectionFailed, which the watchdog reports as
    /// "server rejected". This check exposes the real cause so the toast
    /// can tell the user to disable the other VPN.
    ///
    /// Detection scans BSD interfaces for utun*/ipsec* devices that hold
    /// an IPv4 address outside our own 172.19.0.0/30 TUN range (set in
    /// backend/internal/vpn/clientconfig.go).
    static func anotherVPNActive() -> Bool {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return false }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr = ifaddrPtr
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let name = String(cString: cur.pointee.ifa_name)
            guard name.hasPrefix("utun") || name.hasPrefix("ipsec") else { continue }
            guard let sa = cur.pointee.ifa_addr else { continue }
            guard sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var sin = sockaddr_in()
            memcpy(&sin, UnsafeRawPointer(sa), MemoryLayout<sockaddr_in>.size)
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(cString: buf)
            if !ip.hasPrefix("172.19.") {
                return true
            }
        }
        return false
    }
}
