import Foundation

// ============================================================================
// MARK: - Deployment Configuration
// Edit these values before building to match your server setup.
// ============================================================================

enum AppConfig {
    /// Your server's base URL (with https://)
    static let baseURL = "https://api.madfrog.online"

    /// Fallback base URL (direct IP via HTTP, bypasses Cloudflare/RKN).
    /// Points at NL (sole production backend as of 2026-05-25; DE retired).
    static let fallbackBaseURL = "http://147.45.252.234"

    /// Russian relay (SPB) — highest priority fallback for users in Russia
    static let russianRelayURL = "http://185.218.0.43"

    /// Hardcoded backend IPs for TLS-with-custom-SNI direct dial.
    /// When Cloudflare stalls (RU SNI filtering), we race these as
    /// parallel NWConnection attempts carrying SNI = baseURL host, so
    /// nginx on the server still accepts the TLS handshake.
    ///
    /// NOTE: 162.19.242.30 (DE/OVH Frankfurt) was retired 2026-05-25
    /// and removed from this pool as part of TD-DE-PRUNE.
    ///
    /// 2026-07-11: NL and SPB REMOVED after live verification found both
    /// return a fast, empty-body HTTP 400 on this exact path (curl —resolve
    /// api.madfrog.online:443:<ip> .../api/v1/mobile/config → 400 in
    /// ~0.3-0.4s from both). NL's chameleon backend was stopped by the
    /// 2026-06-29 WAW failover (WAW is primary now, NL is a DB-only streaming
    /// replica) — its nginx no longer proxies this route. SPB is separately
    /// confirmed application-dead as of today's stability audit (roadmap
    /// SPB-RECOVER, P0) — TCP-open but nothing real answers behind it.
    /// Under `.anyBelow500` these fast wrong-status legs could win the race
    /// (`for try await result in group` takes the FIRST passing result, not
    /// the best one) BEFORE a slower-but-correct primary/decoy/MSK leg ever
    /// completed — the exact mechanism behind build 126's "Нет конфигурации"
    /// on a real device. MSK is the only entry left: verified live (curl)
    /// to correctly reach the app layer (401 on an unauthed request) in
    /// ~0.15-0.2s. Re-add NL/SPB here only once they're confirmed serving
    /// this route again — don't restore from memory of the old topology.
    static let directBackendIPs: [String] = [
        // RU-NO-VPN-LOGIN (2026-06-17): MSK relay. It fronts
        // api.madfrog.online on :443 with a valid Let's Encrypt cert and is
        // reachable from RU networks WITHOUT a VPN — unlike a DNS-poisoned
        // api.madfrog.online primary. Without this a RU user with no VPN had
        // no reachable backend path → "all paths failed" sign-in (verified:
        // MSK:443 health 200, cert valid).
        "217.198.5.52",   // MSK relay (RU) — api front, valid cert, RU-reachable
    ]

    /// Host portion of baseURL, used as SNI for direct-IP dial.
    static var baseURLHost: String {
        URL(string: baseURL)?.host ?? "madfrog.online"
    }

    // RU-DECOY-SNI (2026-06-17): the single most-reliable backend path on a
    // hostile RU network without a VPN. Measured root cause: RKN's TSPU
    // SNI-filters `api.madfrog.online` and RSTs the TLS connection (sometimes
    // mid-response — the server logs 200 but the client never receives it),
    // which is why every existing race leg (all present that SNI) fails
    // together, and why sign-in works only with a VPN on. This leg dials the
    // MSK relay with a CLEAN SNI the filter ignores — `ads.adfox.ru`, the same
    // camouflage SNI the VPN data-plane already uses successfully — and routes
    // to the API via the HTTP Host header. MSK serves a self-signed cert we
    // PIN (decoyCertPin), so the leg is dropped if a network SNI-hijacks
    // ads.adfox.ru to the real adfox — credentials never leak.
    static let decoySNI = "ads.adfox.ru"
    static let decoyRelayIP = "217.198.5.52"   // MSK relay (RU, domestic)
    /// RU-DECOY-2ND (PRODUCT-MATURITY-LOOP 2026-06-21): race the clean-SNI decoy
    /// across BOTH RU relays so RU sign-in isn't single-legged (MSK alone was a
    /// SPOF — real-data finding 2026-06-21). Both serve the SAME pinned cert, so
    /// decoyCertPin validates either. SPB's decoy is on :8443 (a separate port that
    /// does NOT touch SPB's live VPN :443 passthrough). A relay not yet serving the
    /// decoy pin-mismatches and drops out → safe to ship before SPB is wired.
    static let decoyRelays: [(ip: String, port: UInt16)] = [
        ("217.198.5.52", 443),    // MSK — direct :443 decoy vhost
        ("185.218.0.43", 8443),   // SPB — :8443 (off the live VPN :443 stream)
    ]
    /// Leaf-cert DER SHA-256 (lowercase hex) of /etc/nginx/decoy/adfox.crt (same on MSK + SPB).
    static let decoyCertPin = "497b4ffdc53c9763db397e0453fa70fd16233a2368d081ee06a4106e9a9a82c9"

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
    static let storeCountryKey = "storeCountryCode"   // cached App Store storefront (X-Store-Country)
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

    // ACCT-IDENTITY (2026-06-01): durable identity markers (Keychain). These
    // are what stop the app from demoting an Apple/Google/email user to a fresh
    // anonymous trial on a transient session failure. authProvider gates the
    // anon-register fallback; appleUserID (the SiwA `sub`) drives launch-time
    // getCredentialState + silent re-auth.
    static let authProviderKey = "authProvider"
    static let appleUserIDKey = "appleUserID"

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

    // One-shot migration guards. Each key, once set, prevents the migration
    // from running again on subsequent launches. Bumped per release.
    static let migrationLeafToCountryV32Key = "migration.leafToCountry.v32"

    // LAUNCH-07: Auto-connect on untrusted Wi-Fi via NEOnDemandRule.
    // All three live in App Group UserDefaults so the PacketTunnel extension
    // could read them in the future (today only the main app writes the rules).
    /// Bool, default OFF. When ON the manager carries On-Demand rules that
    /// auto-trigger the VPN on any Wi-Fi whose SSID is NOT in the trusted list.
    static let autoConnectUntrustedWiFiKey = "autoConnect.untrustedWiFi"
    /// Bool, default OFF. Separate opt-in for cellular. When ON the rule set
    /// also includes a `.cellular` Connect rule so the VPN comes up on LTE/5G.
    /// Kept separate from the Wi-Fi toggle because the UX implications differ
    /// (battery, mobile data cap) — users in censored countries can enable it,
    /// everyone else leaves it OFF.
    static let autoConnectCellularKey = "autoConnect.cellular"
    /// `[String]` of SSIDs the user trusts (home, office). When the device is
    /// on one of these networks, the On-Demand rules tell iOS to NOT bring up
    /// the VPN. Stored verbatim — Apple has restricted live SSID introspection
    /// since iOS 13, so the user enters these manually rather than us
    /// auto-detecting the current network's name.
    static let trustedWiFiSSIDsKey = "autoConnect.trustedSSIDs"

    // LAUNCH-08: Disconnect notification.
    /// Persistent flag set after we've asked the user for notification
    /// authorisation at least once. Used so we don't keep retrying the
    /// authorisation request every connect attempt.
    static let disconnectNotifyAuthRequestedKey = "disconnectNotify.authRequested"
    /// UNNotificationCategory identifier for the "VPN disconnected" alert
    /// with its "Reconnect" action button.
    static let disconnectNotificationCategoryID = "vpn-disconnect"
    /// UNNotificationRequest identifier for the disconnect alert. Reused so
    /// a repeated drop while one is still on screen replaces in place.
    static let disconnectNotificationID = "vpn-disconnect"
    /// Action identifier for the "Reconnect" button on the disconnect alert.
    static let disconnectNotificationReconnectActionID = "RECONNECT"
}
