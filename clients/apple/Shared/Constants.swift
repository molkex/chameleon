import Foundation

// ============================================================================
// MARK: - Deployment Configuration
// Edit these values before building to match your server setup.
// ============================================================================

enum AppConfig {
    /// Your server's base URL (with https://)
    static let baseURL = "https://api.madfrog.online"

    /// Fallback base URL (direct IP via HTTP, bypasses Cloudflare/RKN)
    static let fallbackBaseURL = "http://162.19.242.30"

    /// Russian relay (SPB) — highest priority fallback for users in Russia
    static let russianRelayURL = "http://185.218.0.43"

    /// Hardcoded backend IPs for TLS-with-custom-SNI direct dial.
    /// When Cloudflare stalls (RU SNI filtering), we race these as
    /// parallel NWConnection attempts carrying SNI = baseURL host, so
    /// nginx on the server still accepts the TLS handshake.
    static let directBackendIPs: [String] = [
        "162.19.242.30",  // DE (OVH Frankfurt, main)
        "147.45.252.234", // NL (Timeweb)
        "185.218.0.43"    // SPB relay (RU) — HTTPS 443 may hijack, HTTP 80 untested
    ]

    /// Host portion of baseURL, used as SNI for direct-IP dial.
    static var baseURLHost: String {
        URL(string: baseURL)?.host ?? "madfrog.online"
    }

    /// App Group ID (must match your provisioning profile)
    static let appGroupID = "group.com.madfrog.vpn"

    /// Network Extension bundle ID
    static let tunnelBundleID = "com.madfrog.vpn.tunnel"

    /// App name shown in UI
    static let appName = "MadFrog"

    /// VPN profile description shown in iOS Settings
    static let vpnProfileDescription = "MadFrog VPN"

    /// User-Agent for telemetry
    static let userAgent = "MadFrog-iOS"

    /// Logger subsystem identifier
    static let logSubsystem = "com.madfrog.vpn"
}

// ============================================================================
// MARK: - Internal Constants (no need to change)
// ============================================================================

enum AppConstants {
    static let appGroupID = AppConfig.appGroupID
    static let tunnelBundleID = AppConfig.tunnelBundleID
    static let baseURL = AppConfig.baseURL
    static let configFileName = "singbox-config.json"
    static let activationKey = "activationUsername"
    static let lastUpdateKey = "lastConfigUpdate"
    static let startOptionsKey = "startOptions"

    static var sharedContainerURL: URL {
        // App Group container is the ONLY path the extension and main app share.
        // Fallback to .documentDirectory used to silently split the two processes
        // into separate sandboxes — extension logs became invisible to the UI
        // reader, and config reads/writes silently desynced. If the entitlement
        // is misconfigured we must fail loud, not pretend.
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            fatalError("App Group container for '\(appGroupID)' is unavailable. Check entitlements on main app AND extension targets.")
        }
        return url
    }

    static var configFileURL: URL {
        sharedContainerURL.appendingPathComponent(configFileName)
    }

    static var commandSocketPath: String {
        sharedContainerURL.appendingPathComponent("command.sock").path
    }

    static var workingDirectory: URL {
        sharedContainerURL.appendingPathComponent("sing-box")
    }

    static var tempDirectory: URL {
        sharedContainerURL.appendingPathComponent("sing-box-tmp")
    }

    static let onboardingCompletedKey = "onboardingCompleted"
    static let grpcAvailableKey = "grpcAvailable"
    static let selectedServerTagKey = "selectedServerTag"
    static let subscriptionExpireKey = "subscriptionExpire"
    /// Set to true once the user has completed a real purchase (StoreKit IAP or
    /// FreeKassa web payment). Stays true once set — used by the UI to
    /// distinguish a free trial entitlement from a paid subscription so the
    /// "PRO ACTIVE" badge only appears for paid users. App Review build-74
    /// rejection (Guideline 2.1(a), round 4) flagged "Pro status awarded by
    /// default" because the 3-day backend trial rendered as "PRO ACTIVE" on a
    /// fresh install with no purchase. See incident
    /// 2026-05-15-app-review-iap-not-found.
    static let hasPaidEverKey = "hasPaidEver"
    // Routing mode: "smart" (default) | "ru-direct" | "full-vpn".
    // Controls the three sing-box selectors: "RU Traffic", "Blocked Traffic",
    // "Default Route". See RoutingMode.applyToClash() for the mapping.
    static let routingModeKey = "routingMode"
    static let clashAPIPort = 9091

    // Cross-process VPN state — both main app and PacketTunnel extension
    // read/write these via the App Group UserDefaults. Centralised here so a
    // typo in either binary cannot silently break the stop-from-Settings flow.
    static let vpnConnectedAtKey = "vpnConnectedAt"
    static let userStoppedVPNKey = "user_stopped_vpn"

    // Mobile JWT auth tokens (stored in Keychain)
    static let accessTokenKey = "mobileAccessToken"
    static let refreshTokenKey = "mobileRefreshToken"

    // Authenticated config endpoint
    static let mobileConfigURL = baseURL + "/api/v1/mobile/config"

    // Tunnel health probe endpoint — public, no auth, returns a 32 KB
    // body. Sized to actually traverse RU LTE bulk-traffic throttles
    // (small probes pass even when bulk is throttled) so the iOS
    // TunnelStallProbe can detect "handshake-OK-but-throttled" paths
    // that sing-box's HEAD-based urltest probe cannot see on its own.
    static let mobileHealthcheckURL = baseURL + "/api/v1/mobile/healthcheck"

    // Auto-recover from server failures (TrafficHealthMonitor).
    // Default ON. User can disable from Settings → Diagnostics.
    static let autoRecoverEnabledKey = "autoRecoverEnabled"
    /// launch-06: user preference — keep the VPN on automatically (iOS
    /// Connect-On-Demand). Default OFF (opt-in). When ON, a successful
    /// connect installs an unconditional NEOnDemandRuleConnect so the
    /// tunnel re-establishes after network changes / crashes. An explicit
    /// in-app or iOS-Settings disconnect still clears On-Demand (handled
    /// in VPNManager.disconnect + the userStoppedVPN path), so the user
    /// can always truly turn it off.
    static let autoConnectEnabledKey = "autoConnectEnabled"

    /// Build-39: PacketTunnel extension writes a Date.timeIntervalSince1970
    /// here when its TunnelStallProbe detects a stall (2 consecutive captive-
    /// portal probe misses). Main app reads this on every foreground
    /// transition and on every TrafficHealthMonitor tick — if the timestamp
    /// is newer than the last fallback we ran, AppState invokes
    /// performFallbackForCurrentLeg synchronously. This is the IPC channel
    /// from the extension (which iOS keeps alive while the tunnel is up) to
    /// the main app (which iOS suspends while the user is in Safari) so a
    /// stalled leaf can be replaced even while MadFrog is in the background.
    static let tunnelStallRequestedAtKey = "tunnel_stall_requested_at"
    /// Last timestamp the main app actually serviced an extension stall
    /// request — set by AppState after performFallbackForCurrentLeg runs.
    /// Compared against `tunnelStallRequestedAtKey` to dedup.
    static let tunnelStallServicedAtKey = "tunnel_stall_serviced_at"
    /// Darwin notification name posted by the extension so the main app can
    /// react without a scene-phase change (works while backgrounded, not suspended).
    static let tunnelStallDarwinNotification = "com.madfrog.vpn.tunnelStall"
    /// UNUserNotificationCenter identifier for the in-tunnel stall banner.
    static let tunnelStallNotificationID = "tunnel-stall"
    /// UNUserNotificationCenter identifier for the unexpected-disconnect
    /// banner (launch-07). Single id so a fresh drop replaces a stale one.
    static let disconnectNotificationID = "vpn-disconnected"
    /// UserDefaults guard: set once the app has asked for notification
    /// authorization, so we only prompt the user a single time (after the
    /// first successful connect, not at cold launch).
    static let didRequestNotificationAuthKey = "didRequestNotificationAuth"

    // One-shot migration guards. Each key, once set, prevents the migration
    // from running again on subsequent launches. Bumped per release.
    static let migrationLeafToCountryV32Key = "migration.leafToCountry.v32"
}
