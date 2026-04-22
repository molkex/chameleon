import Foundation

/// Three-way routing mode shared between the main app and the PacketTunnel
/// extension. Maps a user-facing mode to the three sing-box selector states.
///
/// The selectors "RU Traffic", "Blocked Traffic", and "Default Route" exist in
/// the generated client config (see backend-go/internal/vpn/clientconfig.go).
/// Switching mode = three Clash API PUT calls; no reconnect needed.
enum RoutingMode: String, CaseIterable, Codable {
    /// Only RKN-blocked resources (refilter list) go through the VPN.
    /// Everything else — including RU geoip and the global internet — stays on
    /// the native connection. Minimises both bandwidth and VPN-detection signal.
    case smart

    /// RU geoip + always-direct stays native; everything else through VPN.
    /// Classic split-tunneling behaviour.
    case ruDirect = "ru-direct"

    /// Everything through the tunnel (except the hardcoded always-direct list).
    /// Useful when travelling or on hostile public Wi-Fi.
    case fullVPN = "full-vpn"

    /// Full VPN is the default because most users installing a VPN want
    /// "mask my IP everywhere". Smart mode is advanced tier — available,
    /// but not surprising the new user with "connected but whoer shows
    /// my real IP, what's broken?".
    static let `default`: RoutingMode = .fullVPN

    /// Selector → target outbound mapping for this mode.
    /// These are the three PUT requests the extension issues to the local
    /// Clash API after the engine starts or on user toggle.
    var selectorTargets: [(selector: String, target: String)] {
        switch self {
        case .smart:
            return [
                ("RU Traffic",      "direct"),
                ("Blocked Traffic", "Proxy"),
                ("Default Route",   "direct"),
            ]
        case .ruDirect:
            return [
                ("RU Traffic",      "direct"),
                ("Blocked Traffic", "Proxy"),
                ("Default Route",   "Proxy"),
            ]
        case .fullVPN:
            return [
                ("RU Traffic",      "Proxy"),
                ("Blocked Traffic", "Proxy"),
                ("Default Route",   "Proxy"),
            ]
        }
    }
}
