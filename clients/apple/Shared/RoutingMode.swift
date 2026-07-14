import Foundation

/// Three-way routing mode shared between the main app and the PacketTunnel
/// extension. Maps a user-facing mode to the three sing-box selector states.
///
/// The selectors "RU Traffic", "Blocked Traffic", and "Default Route" exist in
/// the generated client config (see backend/internal/vpn/clientconfig.go).
/// Switching mode = three Clash API PUT calls; no reconnect needed.
enum RoutingMode: String, CaseIterable, Codable {
    /// RU geoip + always-direct stays native; everything else through VPN.
    /// Classic split-tunneling behaviour.
    case ruDirect = "ru-direct"

    /// Everything through the tunnel (except the hardcoded always-direct list).
    /// Useful when travelling or on hostile public Wi-Fi.
    case fullVPN = "full-vpn"

    /// RU Direct is the default. Russian sites don't gain anything from a
    /// detour through a European exit — it's only added latency, and it
    /// burns exit-node bandwidth on traffic nobody needed masked in the
    /// first place. Everything foreign — Telegram, Gemini, Google Flow, you
    /// name it — still goes through the VPN untouched.
    ///
    /// A persisted `smart` (retired 2026-07-14, OOM-REFILTER) no longer decodes,
    /// so `RoutingMode(rawValue:) ?? .default` migrates those users here — which
    /// is still the safe direction: "Default Route" (everything that isn't RU)
    /// stays on Proxy, only the RU-specific selector is exempted.
    static let `default`: RoutingMode = .ruDirect

    /// Selector → target outbound mapping for this mode: the PUT requests
    /// issued to the local Clash API after the engine starts or on user toggle.
    ///
    /// "Blocked Traffic" is gone: it only ever existed to catch the RKN
    /// `refilter` rule-set, whose 4.8 MB in-RAM footprint was oom-killing the
    /// extension. Default Route = Proxy now covers that traffic by default.
    var selectorTargets: [(selector: String, target: String)] {
        switch self {
        case .ruDirect:
            return [
                ("RU Traffic",    "direct"),
                ("Default Route", "Proxy"),
            ]
        case .fullVPN:
            return [
                ("RU Traffic",    "Proxy"),
                ("Default Route", "Proxy"),
            ]
        }
    }
}
