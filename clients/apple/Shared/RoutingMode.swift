import Foundation

/// Three-way routing mode shared between the main app and the PacketTunnel
/// extension. Maps a user-facing mode to the three sing-box selector states.
///
/// The selectors "RU Traffic", "Blocked Traffic", and "Default Route" exist in
/// the generated client config (see backend/internal/vpn/clientconfig.go).
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

    /// Build 58 (2026-05-13): default changed .fullVPN → .ruDirect.
    /// Field log 5:48 PM revealed the failure mode: users see "Умный" first
    /// in the picker, assume "smart = best", switch to it, then everything
    /// that's not in the RKN blocklist (Telegram, Speedtest, most apps)
    /// silently leaves the tunnel and inherits whatever the cellular carrier
    /// does to direct traffic — typically heavy throttle on LTE in RU.
    /// .ruDirect (Split-tunnel) is the balanced default: .ru sites stay
    /// fast on the native connection, everything else gets the VPN's
    /// protection from carrier-level interference. Existing users keep
    /// whatever they saved — only the first-launch / reset default flips.
    static let `default`: RoutingMode = .ruDirect

    /// User-facing recommendation surfaced by the picker. Identical to
    /// `default` today; kept as a separate symbol so we can A/B them
    /// later (e.g. recommend ruDirect to new users while keeping fullVPN
    /// as the technical default for advanced presets).
    static let recommended: RoutingMode = .ruDirect

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
