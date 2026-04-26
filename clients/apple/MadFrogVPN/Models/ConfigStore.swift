import Foundation
import Libbox

/// Manages VPN config storage in App Group shared container.
/// Both main app and PacketTunnel extension access this.
class ConfigStore {
    private let sharedDefaults: UserDefaults?

    init() {
        let suite = UserDefaults(suiteName: AppConstants.appGroupID)
        self.sharedDefaults = suite
        if suite == nil {
            // App Group not configured in entitlements — every read returns
            // nil and writes silently no-op, leading to "settings don't
            // persist" reports that are hard to triage. ROADMAP iOS-18.
            AppLogger.app.error("ConfigStore: UserDefaults(suiteName: \(AppConstants.appGroupID)) returned nil — App Group entitlement misconfigured")
        }
    }

    /// Proxy outbound types that represent real servers (not routing constructs).
    private static let proxyOutboundTypes: Set<String> = [
        "vless", "vmess", "trojan", "shadowsocks", "hysteria", "hysteria2", "wireguard", "tuic"
    ]

    /// Outbound types that are routing/grouping constructs, not real servers.
    private static let metaOutboundTypes: Set<String> = [
        "direct", "block", "dns", "selector", "urltest"
    ]

    var isActivated: Bool {
        username != nil || accessToken != nil
    }

    var username: String? {
        get {
            // Prefer Keychain, fallback to UserDefaults for migration
            if let kc = KeychainHelper.load(key: "username") { return kc }
            if let ud = sharedDefaults?.string(forKey: AppConstants.activationKey) {
                // Migrate to Keychain
                KeychainHelper.save(key: "username", value: ud)
                sharedDefaults?.removeObject(forKey: AppConstants.activationKey)
                return ud
            }
            return nil
        }
        set {
            if let v = newValue {
                KeychainHelper.save(key: "username", value: v)
            } else {
                KeychainHelper.delete(key: "username")
            }
            // Clean up legacy UserDefaults
            sharedDefaults?.removeObject(forKey: AppConstants.activationKey)
        }
    }

    // MARK: - JWT Tokens (mobile auth)

    var accessToken: String? {
        get { KeychainHelper.load(key: AppConstants.accessTokenKey) }
        set {
            if let v = newValue { KeychainHelper.save(key: AppConstants.accessTokenKey, value: v) }
            else { KeychainHelper.delete(key: AppConstants.accessTokenKey) }
        }
    }

    var refreshToken: String? {
        get { KeychainHelper.load(key: AppConstants.refreshTokenKey) }
        set {
            if let v = newValue { KeychainHelper.save(key: AppConstants.refreshTokenKey, value: v) }
            else { KeychainHelper.delete(key: AppConstants.refreshTokenKey) }
        }
    }

    var subscriptionURL: String? {
        guard let user = username else { return nil }
        return "\(AppConstants.baseURL)/sub/\(user)/smart"
    }

    var subscriptionExpire: Date? {
        get { sharedDefaults?.object(forKey: AppConstants.subscriptionExpireKey) as? Date }
        set { sharedDefaults?.set(newValue, forKey: AppConstants.subscriptionExpireKey) }
    }

    var lastUpdate: Date? {
        sharedDefaults?.object(forKey: AppConstants.lastUpdateKey) as? Date
    }

    // MARK: - VPN Mode Preference

    var vpnMode: String {
        get { sharedDefaults?.string(forKey: "vpnMode") ?? "smart" }
        set { sharedDefaults?.set(newValue, forKey: "vpnMode") }
    }

    // MARK: - Selected Server Preference

    var selectedServerTag: String? {
        get { sharedDefaults?.string(forKey: AppConstants.selectedServerTagKey) }
        set { sharedDefaults?.set(newValue, forKey: AppConstants.selectedServerTagKey) }
    }

    // MARK: - Auto-recover Preference

    /// Whether TrafficHealthMonitor is allowed to switch the user off a dead
    /// server automatically. Default ON. Stored in App Group UserDefaults so
    /// the user's choice survives reinstalls of the app extension.
    var autoRecoverEnabled: Bool {
        get {
            // First-run: no key present → default ON.
            guard let raw = sharedDefaults?.object(forKey: AppConstants.autoRecoverEnabledKey) else {
                return true
            }
            return (raw as? Bool) ?? true
        }
        set { sharedDefaults?.set(newValue, forKey: AppConstants.autoRecoverEnabledKey) }
    }

    // MARK: - Config Save/Load

    func saveConfig(_ jsonString: String) throws {
        // Sanitize for iOS (remove deprecated fields) before validation
        let sanitized = ConfigSanitizer.sanitizeForIOS(jsonString)

        // Skip LibboxCheckConfig — it rejects dns outbound as "removed in 1.13"
        // but the runtime (startOrReloadService) still accepts it.
        // DNS interception requires dns outbound in this libbox version (1.13.5).

        // Ensure directories exist
        try FileManager.default.createDirectory(
            at: AppConstants.workingDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: AppConstants.tempDirectory,
            withIntermediateDirectories: true
        )

        try sanitized.write(to: AppConstants.configFileURL, atomically: true, encoding: .utf8)
        // Also update persisted start options so On Demand reconnects use fresh config
        sharedDefaults?.set(sanitized, forKey: AppConstants.startOptionsKey)
        sharedDefaults?.set(Date(), forKey: AppConstants.lastUpdateKey)
        AppLogger.app.info("Config saved (sanitized), length: \(sanitized.count)")
    }

    func loadConfig() -> String? {
        try? String(contentsOf: AppConstants.configFileURL, encoding: .utf8)
    }

    func hasConfig() -> Bool {
        FileManager.default.fileExists(atPath: AppConstants.configFileURL.path)
    }

    func clear() {
        try? FileManager.default.removeItem(at: AppConstants.configFileURL)
        // Setting these to nil already removes the underlying Keychain
        // items (see each property's setter). Don't double-delete username.
        username = nil
        subscriptionExpire = nil
        accessToken = nil
        refreshToken = nil
        sharedDefaults?.removeObject(forKey: AppConstants.activationKey)
        sharedDefaults?.removeObject(forKey: AppConstants.lastUpdateKey)
        sharedDefaults?.removeObject(forKey: AppConstants.startOptionsKey)
        sharedDefaults?.removeObject(forKey: AppConstants.selectedServerTagKey)
    }

    // MARK: - Parse Servers from Config

    /// Parse the saved sing-box config JSON into the UI's server list model.
    ///
    /// Architecture (build-39+, post `urltest` removal):
    ///   - `Proxy` selector is the top-level picker. Its `outbounds` list
    ///     is now FLAT: every leaf (vless/hysteria2/tuic outbounds) plus
    ///     optionally one whitelist-bypass selector group
    ///     ("🇷🇺 Россия (обход белых списков)") whose own members are the
    ///     SPB leaves.
    ///   - Country grouping is derived client-side from leaf-tag prefixes
    ///     (de-*, nl-*, ru-spb-*) — there are no urltest outbounds in the
    ///     config to read groups from. See `PathPicker.swift` header for
    ///     why this lives in the host process now.
    ///   - Leaf tags are opaque short IDs ("de-direct-de", "nl-via-msk");
    ///     display name + flag come from a hardcoded mapping below
    ///     (`Self.countryDisplay`) since the backend no longer ships them.
    ///
    /// Returned shape:
    ///   A single `ServerGroup` with tag="Proxy", `items` = every leaf
    ///   server. `countries` is built virtually by grouping leaves by their
    ///   prefix. `hasAuto = true` always (Auto is now a synthetic UI mode
    ///   handled by PathPicker — not a real outbound).
    ///
    /// Fallback: if a usable "Proxy" selector isn't found (older configs,
    /// direct-only configs), fall back to scanning standalone leaf
    /// outbounds and wrapping them in a single synthetic group.
    func parseServersFromConfig() -> [ServerGroup] {
        guard let jsonString = loadConfig(),
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = json["outbounds"] as? [[String: Any]]
        else {
            return []
        }

        var byTag: [String: [String: Any]] = [:]
        for ob in outbounds {
            if let tag = ob["tag"] as? String { byTag[tag] = ob }
        }

        // Locate the Proxy selector.
        guard let proxy = outbounds.first(where: {
            ($0["type"] as? String) == "selector" && ($0["tag"] as? String) == "Proxy"
        }) else {
            return fallbackGroup(from: outbounds)
        }
        let proxyMembers = proxy["outbounds"] as? [String] ?? []

        // Resolve each leaf outbound tag reachable from a given tag. Walks
        // through urltest/selector members recursively; stops at anything
        // in `proxyOutboundTypes`. Cycles are guarded by `visited`.
        func resolveLeaves(from tag: String, visited: inout Set<String>) -> [ServerItem] {
            if visited.contains(tag) { return [] }
            visited.insert(tag)
            guard let ob = byTag[tag], let type = ob["type"] as? String else { return [] }
            if Self.proxyOutboundTypes.contains(type) {
                let host = (ob["server"] as? String) ?? ""
                let port = (ob["server_port"] as? Int) ?? 0
                return [ServerItem(id: tag, tag: tag, type: type, delay: 0, delayTime: 0, host: host, port: port)]
            }
            if type == "urltest" || type == "selector" {
                let members = ob["outbounds"] as? [String] ?? []
                var out: [ServerItem] = []
                for m in members {
                    out.append(contentsOf: resolveLeaves(from: m, visited: &visited))
                }
                return out
            }
            return []
        }

        // Build-39: collect every leaf (recursively) reachable from any
        // Proxy member, then group leaves by tag-prefix into virtual
        // CountryGroups. The backend's `clientconfig.go` no longer emits
        // urltest groups, so we derive country structure on-device.
        // Leaves directly under Proxy + leaves under any sub-selector
        // (notably the whitelist-bypass group) are all collected.
        var allLeaves: [ServerItem] = []
        var leafSeen = Set<String>()

        for memberTag in proxyMembers {
            var visited = Set<String>()
            let leaves = resolveLeaves(from: memberTag, visited: &visited)
            for leaf in leaves where !leafSeen.contains(leaf.tag) {
                leafSeen.insert(leaf.tag)
                allLeaves.append(leaf)
            }
        }

        if allLeaves.isEmpty {
            return fallbackGroup(from: outbounds)
        }

        // Group leaves by country prefix (de-*, nl-*, ru-spb-*) and build a
        // virtual CountryGroup per bucket. Order: NL first (LTE-native),
        // then alphabetical, then whitelist-bypass last. Match backend's
        // legSortKey ordering inside each country (direct, via, h2, tuic).
        let countryGroups = Self.buildVirtualCountryGroups(from: allLeaves)

        let savedTag = selectedServerTag
        let selected: String = {
            if let s = savedTag {
                // Saved tag may be a leaf, a country display tag, or "Auto".
                if byTag[s] != nil { return s }
                if Self.countryDisplay.values.contains(s) { return s }
                if s == "Auto" { return s }
            }
            return "Auto"
        }()

        return [ServerGroup(
            id: "Proxy",
            tag: "Proxy",
            type: "selector",
            selected: selected,
            items: allLeaves,
            selectable: true,
            hasAuto: true, // Auto is always available — synthetic UI mode now.
            countries: countryGroups
        )]
    }

    // MARK: - Build-39: virtual country grouping

    /// Display labels for country code prefixes. Mirrors backend's
    /// `clientconfig.go::countryDisplay` so picker entries match what the
    /// build-32 migration / `selectedServerTag` logic expects.
    static let countryDisplay: [String: String] = [
        "de": "🇩🇪 Германия",
        "nl": "🇳🇱 Нидерланды",
        "ru-spb": "🇷🇺 Россия (обход белых списков)"
    ]

    /// Country code derived from a leaf tag's prefix. Mirrors
    /// `LeafCandidate.country` so picker grouping and PathPicker selection
    /// agree on which leaves belong to which country.
    private static func countryCode(forLeafTag tag: String) -> String {
        if tag.hasPrefix("ru-spb-") { return "ru-spb" }
        return tag.split(separator: "-").first.map(String.init) ?? ""
    }

    /// Stable sort key inside a country: direct, then via, then h2, then
    /// tuic, then anything else. Mirrors backend's `legSortKey` so logs +
    /// UI ordering line up.
    private static func legSortKey(_ tag: String) -> String {
        if tag.contains("-direct-") { return "0-" + tag }
        if tag.contains("-via-")    { return "1-" + tag }
        if tag.contains("-h2-")     { return "2-" + tag }
        if tag.contains("-tuic-")   { return "3-" + tag }
        return "9-" + tag
    }

    private static func buildVirtualCountryGroups(from leaves: [ServerItem]) -> [CountryGroup] {
        // Bucket by country code.
        var buckets: [String: [ServerItem]] = [:]
        for leaf in leaves {
            let cc = countryCode(forLeafTag: leaf.tag)
            guard !cc.isEmpty else { continue }
            buckets[cc, default: []].append(leaf)
        }

        // Sort countries: NL first, then alphabetical, ru-spb always last.
        let order: [String] = buckets.keys.sorted { a, b in
            if a == "ru-spb" && b != "ru-spb" { return false }
            if b == "ru-spb" && a != "ru-spb" { return true }
            if a == "nl" && b != "nl" { return true }
            if b == "nl" && a != "nl" { return false }
            return a < b
        }

        return order.compactMap { cc in
            guard var items = buckets[cc], !items.isEmpty else { return nil }
            items.sort { legSortKey($0.tag) < legSortKey($1.tag) }
            let display = countryDisplay[cc] ?? cc
            return CountryGroup.from(urltestTag: display, items: items)
        }
    }

    /// Fallback for configs that don't follow the Proxy/urltest layout.
    /// Wraps every leaf outbound into a single synthetic group.
    private func fallbackGroup(from outbounds: [[String: Any]]) -> [ServerGroup] {
        let leaves: [ServerItem] = outbounds.compactMap { ob in
            guard let type = ob["type"] as? String,
                  let tag = ob["tag"] as? String,
                  Self.proxyOutboundTypes.contains(type)
            else { return nil }
            let host = (ob["server"] as? String) ?? ""
            let port = (ob["server_port"] as? Int) ?? 0
            return ServerItem(id: tag, tag: tag, type: type, delay: 0, delayTime: 0, host: host, port: port)
        }
        guard !leaves.isEmpty else { return [] }
        let savedTag = selectedServerTag
        let selected = leaves.first(where: { $0.tag == savedTag })?.tag ?? leaves.first?.tag ?? ""
        return [ServerGroup(
            id: "Proxy",
            tag: "Proxy",
            type: "selector",
            selected: selected,
            items: leaves,
            selectable: true,
            hasAuto: false,
            countries: []
        )]
    }
}
