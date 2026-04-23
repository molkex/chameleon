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
        username = nil
        subscriptionExpire = nil
        accessToken = nil
        refreshToken = nil
        KeychainHelper.delete(key: "username")
        sharedDefaults?.removeObject(forKey: AppConstants.activationKey)
        sharedDefaults?.removeObject(forKey: AppConstants.lastUpdateKey)
        sharedDefaults?.removeObject(forKey: AppConstants.startOptionsKey)
        sharedDefaults?.removeObject(forKey: AppConstants.selectedServerTagKey)
    }

    // MARK: - Parse Servers from Config

    /// Parse the saved sing-box config JSON to extract server groups and items.
    /// Returns groups structured the same way as gRPC CommandClient provides them,
    /// but without ping data (delay = 0 for all items).
    func parseServersFromConfig() -> [ServerGroup] {
        guard let jsonString = loadConfig(),
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = json["outbounds"] as? [[String: Any]]
        else {
            return []
        }

        // Index all outbounds by tag
        var outboundsByTag: [String: [String: Any]] = [:]
        for ob in outbounds {
            if let tag = ob["tag"] as? String {
                outboundsByTag[tag] = ob
            }
        }

        var groups: [ServerGroup] = []

        // Build urltest group (main server list)
        for ob in outbounds {
            guard let type = ob["type"] as? String,
                  let tag = ob["tag"] as? String
            else { continue }

            if type == "urltest" {
                let memberTags = ob["outbounds"] as? [String] ?? []
                let items = memberTags.compactMap { memberTag -> ServerItem? in
                    guard let member = outboundsByTag[memberTag],
                          let memberType = member["type"] as? String,
                          Self.proxyOutboundTypes.contains(memberType)
                    else { return nil }
                    let host = (member["server"] as? String) ?? ""
                    let port = (member["server_port"] as? Int) ?? 0
                    return ServerItem(
                        id: memberTag,
                        tag: memberTag,
                        type: memberType,
                        delay: 0,
                        delayTime: 0,
                        host: host,
                        port: port
                    )
                }
                if !items.isEmpty {
                    // Use saved selection or first item as "selected"
                    let savedTag = selectedServerTag
                    let selected = items.first(where: { $0.tag == savedTag })?.tag ?? items.first?.tag ?? ""
                    groups.append(ServerGroup(
                        id: tag,
                        tag: tag,
                        type: type,
                        selected: selected,
                        items: items,
                        selectable: true
                    ))
                }
            } else if type == "selector" {
                let memberTags = ob["outbounds"] as? [String] ?? []
                // Exclude nested urltest/selector tags (e.g. "Auto") — those are
                // control outbounds, not real servers, and would otherwise show
                // up as an unrecognized entry in the UI.
                let items = memberTags.compactMap { memberTag -> ServerItem? in
                    guard let member = outboundsByTag[memberTag] else { return nil }
                    let memberType = (member["type"] as? String) ?? "unknown"
                    guard Self.proxyOutboundTypes.contains(memberType) else { return nil }
                    let host = (member["server"] as? String) ?? ""
                    let port = (member["server_port"] as? Int) ?? 0
                    return ServerItem(
                        id: memberTag,
                        tag: memberTag,
                        type: memberType,
                        delay: 0,
                        delayTime: 0,
                        host: host,
                        port: port
                    )
                }
                let defaultSelected = ob["default"] as? String ?? items.first?.tag ?? ""
                groups.append(ServerGroup(
                    id: tag,
                    tag: tag,
                    type: type,
                    selected: defaultSelected,
                    items: items,
                    selectable: true
                ))
            }
        }

        // Fallback for minimal configs (no urltest/selector groups):
        // Create a synthetic group from standalone proxy outbounds
        if groups.isEmpty {
            let standaloneProxies = outbounds.compactMap { ob -> ServerItem? in
                guard let type = ob["type"] as? String,
                      let tag = ob["tag"] as? String,
                      Self.proxyOutboundTypes.contains(type)
                else { return nil }
                let host = (ob["server"] as? String) ?? ""
                let port = (ob["server_port"] as? Int) ?? 0
                return ServerItem(id: tag, tag: tag, type: type, delay: 0, delayTime: 0, host: host, port: port)
            }
            if !standaloneProxies.isEmpty {
                let savedTag = selectedServerTag
                let selected = standaloneProxies.first(where: { $0.tag == savedTag })?.tag ?? standaloneProxies.first?.tag ?? ""
                groups.append(ServerGroup(
                    id: "Proxy",
                    tag: "Proxy",
                    type: "selector",
                    selected: selected,
                    items: standaloneProxies,
                    selectable: true
                ))
            }
        }

        return groups
    }
}
