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
    /// Flag emoji wins over substring matching — a tag like "VLESS 🇷🇺 Russia → DE"
    /// must go to Russia, not Germany (where it would land if we matched "de" first).
    var countryKey: String {
        let t = tag.lowercased()
        // CDN fallback — hidden from UI
        if t.contains("cdn") { return "cdn" }
        // Flag emoji is authoritative — check it first.
        if tag.contains("🇳🇱") { return "nl" }
        if tag.contains("🇩🇪") { return "de" }
        if tag.contains("🇷🇺") { return "ru" }
        // Fallback: substring match on localized/ASCII names.
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
        return t.contains("hysteria") || t.contains("hy2") || type.lowercased() == "hysteria2"
    }

    /// Human-readable label for the individual server row.
    /// Extracts the server name from the tag: backend emits tags like
    /// "VLESS 🇩🇪 Germany" or "VLESS 🇷🇺 Russia → DE", and we want the
    /// trailing name part so the user can distinguish direct vs relay.
    var displayLabel: String {
        let cleaned = tag
            .replacingOccurrences(of: "VLESS", with: "")
            .replacingOccurrences(of: "🇳🇱", with: "")
            .replacingOccurrences(of: "🇩🇪", with: "")
            .replacingOccurrences(of: "🇷🇺", with: "")
            .trimmingCharacters(in: .whitespaces)
        if !cleaned.isEmpty { return cleaned }
        // Fallback for hysteria / cdn / unknown shapes.
        let t = tag.lowercased()
        if isHysteria { return t.contains("relay") ? "HY2 Relay" : "HY2 Direct" }
        if t.contains("cdn") || t.contains("ws") { return "CDN Cloudflare" }
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
struct CountryGroup: Identifiable {
    /// Which section of the server picker this group belongs to.
    enum Section {
        case direct   // normal country entry (NL, DE)
        case relay    // russia-exit relays that tunnel into another country
    }

    let id: String
    let name: String
    /// Two-letter country code (e.g. "NL", "DE", "RU").
    let countryCode: String
    let serverCount: Int
    /// Tags of all individual servers in this group.
    let serverTags: [String]
    /// Best delay among servers in this group (0 = unknown).
    var bestDelay: Int32
    let section: Section

    var bestDelayText: String {
        if bestDelay <= 0 { return "" }
        return "\(bestDelay) ms"
    }

    /// Country flag emoji for use as badge background.
    var flagEmoji: String {
        switch id {
        case "nl": return "🇳🇱"
        case "de": return "🇩🇪"
        case "ru": return "🇷🇺"
        default: return ""
        }
    }

    /// Display order (lower = higher in list).
    var sortOrder: Int {
        switch id {
        case "nl": return 0
        case "de": return 1
        case "ru": return 2
        default: return 10
        }
    }

    /// Short human-readable subtitle for the country row.
    let subtitle: String

    static func from(key: String, items: [ServerItem]) -> CountryGroup {
        let bestDelay = items.filter { $0.delay > 0 }.min(by: { $0.delay < $1.delay })?.delay ?? 0

        switch key {
        case "nl":
            return CountryGroup(
                id: key, name: "Нидерланды", countryCode: "NL",
                serverCount: items.count, serverTags: items.map(\.tag),
                bestDelay: bestDelay, section: .direct,
                subtitle: subtitleForDirect(count: items.count)
            )
        case "de":
            return CountryGroup(
                id: key, name: "Германия", countryCode: "DE",
                serverCount: items.count, serverTags: items.map(\.tag),
                bestDelay: bestDelay, section: .direct,
                subtitle: subtitleForDirect(count: items.count)
            )
        case "ru":
            // Russia-exit relays: each server tunnels into another country.
            return CountryGroup(
                id: key, name: "Россия", countryCode: "RU",
                serverCount: items.count, serverTags: items.map(\.tag),
                bestDelay: bestDelay, section: .relay,
                subtitle: "\(items.count) \(pluralServers(items.count))"
            )
        default:
            return CountryGroup(
                id: key, name: "Другие", countryCode: "—",
                serverCount: items.count, serverTags: items.map(\.tag),
                bestDelay: bestDelay, section: .direct,
                subtitle: ""
            )
        }
    }

    private static func subtitleForDirect(count: Int) -> String {
        if count <= 1 { return "Прямое подключение" }
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

    /// Group items by country for simplified display (CDN hidden).
    var countryGroups: [CountryGroup] {
        var grouped: [String: [ServerItem]] = [:]
        for item in items {
            grouped[item.countryKey, default: []].append(item)
        }
        return grouped
            .filter { $0.key != "cdn" }  // Hide CDN Fallback from UI
            .map { CountryGroup.from(key: $0.key, items: $0.value) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Find which country group contains the currently selected server.
    var selectedCountryKey: String? {
        items.first(where: { $0.tag == selected })?.countryKey
    }
}
