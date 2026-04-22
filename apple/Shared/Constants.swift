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
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
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
    // Routing mode: "smart" (default) | "ru-direct" | "full-vpn".
    // Controls the three sing-box selectors: "RU Traffic", "Blocked Traffic",
    // "Default Route". See RoutingMode.applyToClash() for the mapping.
    static let routingModeKey = "routingMode"
    static let clashAPIPort = 9091

    // Mobile JWT auth tokens (stored in Keychain)
    static let accessTokenKey = "mobileAccessToken"
    static let refreshTokenKey = "mobileRefreshToken"

    // Authenticated config endpoint
    static let mobileConfigURL = baseURL + "/api/v1/mobile/config"
}
