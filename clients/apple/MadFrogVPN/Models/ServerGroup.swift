import Foundation

struct ServerItem: Identifiable {
    let id: String
    let tag: String
    let type: String
    var delay: Int32
    var delayTime: Int64
    /// TCP endpoint for out-of-band latency probing. Parsed from the sing-box
    /// outbound so PingService can measure RTT before the tunnel is up.
    var host: String = ""
    var port: Int = 0

    var delayText: String {
        if delay <= 0 { return "—" }
        return "\(delay) ms"
    }

    /// Two-letter country code for display (e.g. "NL", "DE", "RU").
    var countryCode: String {
        switch countryKey {
        case "nl": return "NL"
        case "de": return "DE"
        case "ru": return "RU"
        case "cdn": return "CDN"
        default: return "—"
        }
    }

    /// Flag emoji for the server's country.
    var flagEmoji: String {
        switch countryKey {
        case "nl": return "🇳🇱"
        case "de": return "🇩🇪"
        case "ru": return "🇷🇺"
        case "cdn": return "🌐"
        default: return "🌍"
        }
    }

    /// SF Symbol name for this server's country.
    var countryIcon: String {
        switch countryKey {
        case "nl", "de", "ru": return "mappin.circle.fill"
        case "cdn": return "cloud.fill"
        default: return "globe"
        }
    }

    var protocolLabel: String {
        switch type.lowercased() {
        case "vless": return "VLESS"
        case "hysteria2": return "HY2"
        case "wireguard": return "WG"
        default: return type.uppercased()
        }
    }

    /// Country grouping key for display purposes.
    ///
    /// Primary source: leaf tag prefix in the new backend format, e.g.
    ///   "nl-direct-nl2"  → "nl"
    ///   "de-via-msk"     → "de"
    ///   "ru-spb-de"      → "ru"
    /// Falls back to flag-emoji and substring matching for older tag formats.
    var countryKey: String {
        let t = tag.lowercased()
        // New format: {cc}-{kind}-{suffix} where cc ∈ {nl, de, ru, ...}
        if let dash = t.firstIndex(of: "-") {
            let prefix = String(t[..<dash])
            if prefix.count == 2, ["nl", "de", "ru"].contains(prefix) {
                return prefix
            }
        }
        // CDN fallback — hidden from UI (legacy).
        if t.contains("cdn") { return "cdn" }
        // Legacy flag-based format.
        if tag.contains("🇳🇱") { return "nl" }
        if tag.contains("🇩🇪") { return "de" }
        if tag.contains("🇷🇺") { return "ru" }
        if t.contains("нидерланды") || t.contains("netherlands") { return "nl" }
        if t.contains("германия") || t.contains("germany") { return "de" }
        if t.contains("россия") || t.contains("russia") || t.contains("москва") { return "ru" }
        return "other"
    }

    /// Short display label extracted from the tag (e.g. "ads", "gRPC", "HY2").
    var shortLabel: String {
        // Extract text inside brackets: "🇳🇱 Нидерланды [ads]" → "ads"
        if let start = tag.firstIndex(of: "["), let end = tag.firstIndex(of: "]"), start < end {
            return String(tag[tag.index(after: start)..<end])
        }
        if isHysteria { return "HY2" }
        if tag.hasSuffix("gRPC") { return "gRPC" }
        if tag.hasSuffix("WS") || tag.contains("CDN") { return "CDN" }
        return tag.components(separatedBy: " ").last ?? tag
    }

    /// Whether this server uses Hysteria2 protocol.
    var isHysteria: Bool {
        let t = tag.lowercased()
        return t.contains("hysteria") || t.contains("hy2") || t.contains("-h2-") || type.lowercased() == "hysteria2"
    }

    /// Human-readable label for the individual server row.
    ///
    /// Recognises the new leaf tag format `{cc}-{kind}-{key}` emitted by
    /// `backend/internal/vpn/clientconfig.go`:
    ///   de-direct-de   → "Напрямую"
    ///   de-h2-de       → "Hysteria2"
    ///   de-tuic-de     → "TUIC"
    ///   de-via-msk     → "Через MSK"
    ///   ru-spb-de      → "SPB → DE"
    /// Unknown shapes fall through to the raw tag.
    var displayLabel: String {
        let parts = tag.split(separator: "-").map(String.init)
        if parts.count >= 3 {
            switch parts[1] {
            case "direct":
                return String(localized: "server.leaf.direct")
            case "h2":
                return "Hysteria2"
            case "tuic":
                return "TUIC"
            case "via":
                // "Через MSK" / "Через SPB"
                let relay = parts.dropFirst(2).joined(separator: "-").uppercased()
                return String(format: String(localized: "server.leaf.via_fmt"), relay)
            case "spb":
                // SPB entry → exit country code from parts[2..]
                let exit = parts.dropFirst(2).joined(separator: "-").uppercased()
                return "SPB → \(exit)"
            default:
                break
            }
        }
        // Legacy flag-prefixed tags.
        let legacyCleaned = tag
            .replacingOccurrences(of: "VLESS", with: "")
            .replacingOccurrences(of: "🇳🇱", with: "")
            .replacingOccurrences(of: "🇩🇪", with: "")
            .replacingOccurrences(of: "🇷🇺", with: "")
            .trimmingCharacters(in: .whitespaces)
        if !legacyCleaned.isEmpty { return legacyCleaned }
        return tag
    }

    /// Full label for the Home screen pill: "Germany", "Russia → DE", "Netherlands".
    /// Matches what the user sees inside the country drill-down so there's
    /// no mismatch between home and picker.
    var homePillLabel: String {
        if countryKey == "cdn" { return "CDN Cloudflare" }
        return displayLabel
    }
}

/// A country-level group of servers displayed to the user.
///
/// Built directly from the backend's country urltest tag (e.g.
/// "🇩🇪 Германия", "🇷🇺 Россия (обход белых списков)"). Display name and
/// flag come from the tag itself — no hardcoded country list — so adding
/// a new country on the backend only needs a DB row, never a client
/// update.
struct CountryGroup: Identifiable {
    /// Which section of the server picker this group belongs to.
    enum Section {
        case direct            // normal country (NL, DE, …) — direct + chain mix
        case whitelistBypass   // legacy SPB relays, shown last, isolated
    }

    /// The urltest tag — also used as the id and as the sing-box Proxy
    /// target when the user selects the whole country (auto-picks between
    /// direct and chain members based on RTT).
    let id: String
    let tag: String
    /// Just the text part of the tag — flag emoji stripped. "Германия",
    /// "Россия (обход белых списков)".
    let name: String
    /// Leading flag emoji (possibly empty for non-country groups).
    let flagEmoji: String
    /// Tags of all leaf servers reachable from this group.
    let serverTags: [String]
    /// Best measured delay among `serverTags` (0 = unknown).
    var bestDelay: Int32
    let section: Section
    let subtitle: String

    var serverCount: Int { serverTags.count }

    var bestDelayText: String {
        if bestDelay <= 0 { return "" }
        return "\(bestDelay) ms"
    }

    /// Stable sort order. Backend already sorts (NL first); we preserve
    /// insertion order, with whitelist-bypass always last regardless.
    var sortOrder: Int {
        section == .whitelistBypass ? 100 : 0
    }

    static func from(urltestTag: String, items: [ServerItem]) -> CountryGroup {
        let bestDelay = items.filter { $0.delay > 0 }.min(by: { $0.delay < $1.delay })?.delay ?? 0
        let (flag, rest) = splitFlagAndName(urltestTag)
        let isWhitelistBypass = rest.lowercased().contains("обход") ||
                                rest.lowercased().contains("whitelist")
        let section: Section = isWhitelistBypass ? .whitelistBypass : .direct
        let subtitle = isWhitelistBypass
            ? String(localized: "server.whitelist_bypass_subtitle")
            : subtitleForDirect(count: items.count)
        return CountryGroup(
            id: urltestTag,
            tag: urltestTag,
            name: rest,
            flagEmoji: flag,
            serverTags: items.map(\.tag),
            bestDelay: bestDelay,
            section: section,
            subtitle: subtitle
        )
    }

    /// Split a tag like "🇩🇪 Германия" into ("🇩🇪", "Германия"). Regional
    /// indicator symbols (U+1F1E6..U+1F1FF) grapheme-cluster into flags;
    /// we grab the first Character, require it to actually be a flag, then
    /// trim+return the remainder.
    private static func splitFlagAndName(_ tag: String) -> (String, String) {
        guard let first = tag.first else { return ("", tag) }
        let firstStr = String(first)
        if firstStr.unicodeScalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) {
            let rest = tag.dropFirst().trimmingCharacters(in: .whitespaces)
            return (firstStr, String(rest))
        }
        return ("", tag)
    }

    private static func subtitleForDirect(count: Int) -> String {
        if count <= 1 { return String(localized: "server.direct_connection") }
        return "\(count) \(pluralServers(count))"
    }

    private static func pluralServers(_ n: Int) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "сервер" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "сервера" }
        return "серверов"
    }
}

struct ServerGroup: Identifiable {
    let id: String
    let tag: String
    let type: String
    var selected: String
    var items: [ServerItem]
    let selectable: Bool

    /// Whether the config includes an "Auto" meta-urltest. When true the
    /// picker renders an "Auto" row at the top; the user's selection for
    /// Auto is the literal tag "Auto" sent to sing-box via Clash API.
    let hasAuto: Bool

    /// Country groups built by `ConfigStore.parseServersFromConfig()` from
    /// the Proxy selector's urltest members. Ordered as the backend
    /// emitted them, with whitelist-bypass pushed last.
    let countries: [CountryGroup]

    /// Legacy alias — some call sites still read `.countryGroups`.
    var countryGroups: [CountryGroup] {
        countries.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// The country group that contains the currently-selected leaf tag,
    /// if any. When the user picks an entire country urltest (not a leaf),
    /// `selected` matches the country's own `tag` and this returns that
    /// country directly.
    var selectedCountryKey: String? {
        if let c = countries.first(where: { $0.tag == selected }) { return c.id }
        return countries.first(where: { $0.serverTags.contains(selected) })?.id
    }
}
