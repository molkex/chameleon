import Foundation

// ============================================================================
// MARK: - Deployment Configuration
// Edit these values before building to match your server setup.
// ============================================================================

enum AppConfig {
    /// Your server's base URL (with https://)
    static let baseURL = "https://razblokirator.ru"

    /// Fallback base URL (direct IP via HTTP, bypasses Cloudflare/RKN)
    static let fallbackBaseURL = "http://162.19.242.30"

    /// Russian relay (SPB) — highest priority fallback for users in Russia
    static let russianRelayURL = "http://185.218.0.43"

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

    // Mobile JWT auth tokens (stored in Keychain)
    static let accessTokenKey = "mobileAccessToken"
    static let refreshTokenKey = "mobileRefreshToken"

    // Authenticated config endpoint
    static let mobileConfigURL = baseURL + "/api/v1/mobile/config"
}
