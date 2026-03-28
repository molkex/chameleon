import Foundation

struct ServerItem: Identifiable {
    let id: String
    let tag: String
    let type: String
    var delay: Int32
    var delayTime: Int64

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
    var countryKey: String {
        let t = tag.lowercased()
        // CDN fallback — hidden from UI
        if t.contains("cdn") { return "cdn" }
        // Country detection (Hysteria2 merges into same country card)
        if tag.contains("🇳🇱") || t.contains("nl") || t.contains("нидерланды") { return "nl" }
        if tag.contains("🇩🇪") || t.contains("de") || t.contains("германия") { return "de" }
        if tag.contains("🇷🇺") || t.contains("ru") || t.contains("москва") { return "ru" }
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
    /// E.g. "HY2 · Relay", "VLESS · TCP", "VLESS · gRPC"
    var displayLabel: String {
        let t = tag.lowercased()
        let isRelay = t.contains("relay")
        if isHysteria { return "HY2 · \(isRelay ? "Relay" : "Direct")" }
        if t.contains("grpc") { return "VLESS · gRPC" }
        if t.contains("cdn") || t.contains("ws") { return "CDN · Cloudflare" }
        return "VLESS · \(isRelay ? "Relay" : "TCP")"
    }

    /// Full label for the Home screen pill: "NL · HY2 Relay", "DE · VLESS TCP", "CDN · Cloudflare".
    var homePillLabel: String {
        let t = tag.lowercased()
        if t.contains("cdn") || (countryKey == "cdn") {
            return "CDN · Cloudflare"
        }
        let isRelay = t.contains("relay")
        let proto: String
        if isHysteria {
            proto = isRelay ? "HY2 Relay" : "HY2 Direct"
        } else if t.contains("grpc") {
            proto = "VLESS gRPC"
        } else {
            proto = isRelay ? "VLESS Relay" : "VLESS TCP"
        }
        return "\(countryCode) · \(proto)"
    }
}

/// A country-level group of servers displayed to the user.
struct CountryGroup: Identifiable {
    let id: String
    let name: String
    /// Two-letter country code (e.g. "NL", "DE", "RU").
    let countryCode: String
    let serverCount: Int
    /// Tags of all individual servers in this group.
    let serverTags: [String]
    /// Best delay among servers in this group (0 = unknown).
    var bestDelay: Int32

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

    /// Subtitle showing protocol breakdown (e.g. "5 VLESS + 1 HY2").
    let subtitle: String

    static func from(key: String, items: [ServerItem]) -> CountryGroup {
        let bestDelay = items.filter { $0.delay > 0 }.min(by: { $0.delay < $1.delay })?.delay ?? 0
        let subtitle = protocolSubtitle(items)

        switch key {
        case "nl":
            return CountryGroup(id: key, name: "Нидерланды", countryCode: "NL",
                                serverCount: items.count, serverTags: items.map(\.tag), bestDelay: bestDelay, subtitle: subtitle)
        case "de":
            return CountryGroup(id: key, name: "Германия", countryCode: "DE",
                                serverCount: items.count, serverTags: items.map(\.tag), bestDelay: bestDelay, subtitle: subtitle)
        case "ru":
            return CountryGroup(id: key, name: "Россия", countryCode: "RU",
                                serverCount: items.count, serverTags: items.map(\.tag), bestDelay: bestDelay, subtitle: subtitle)
        default:
            return CountryGroup(id: key, name: "Другие", countryCode: "—",
                                serverCount: items.count, serverTags: items.map(\.tag), bestDelay: bestDelay, subtitle: subtitle)
        }
    }

    /// Build subtitle like "5 VLESS + 1 HY2"
    private static func protocolSubtitle(_ items: [ServerItem]) -> String {
        var vless = 0, hy2 = 0, other = 0
        for item in items {
            if item.isHysteria { hy2 += 1 }
            else if item.type.lowercased() == "vless" { vless += 1 }
            else { other += 1 }
        }
        var parts: [String] = []
        if vless > 0 { parts.append("\(vless) VLESS") }
        if hy2 > 0 { parts.append("\(hy2) HY2") }
        if other > 0 { parts.append("\(other) \(items.first { !$0.isHysteria && $0.type.lowercased() != "vless" }?.protocolLabel ?? "other")") }
        return parts.joined(separator: " + ")
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
