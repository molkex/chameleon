import Foundation
import SwiftUI
import NetworkExtension
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
class AppState {
    let configStore = ConfigStore()
    let apiClient = APIClient()
    let vpnManager = VPNManager()
    let commandClient = CommandClientWrapper()
    let pingService = PingService()

    @ObservationIgnored private(set) lazy var subscriptionManager: SubscriptionManager = {
        SubscriptionManager { [weak self] signedJWS in
            guard let self, let token = self.configStore.accessToken else {
                throw APIError.unauthorized
            }
            return try await self.apiClient.verifySubscription(signedJWS: signedJWS, accessToken: token)
        }
    }()

    var servers: [ServerGroup] = []
    /// Currently selected server tag, mirrored into configStore (UserDefaults).
    /// Stored here as @Observable so SwiftUI views (pill, ServerListView) react
    /// to user selection without polling. configStore stays the persistence
    /// layer (also read by PacketTunnel extension which has no AppState).
    var selectedServerTag: String?
    var isLoading = false
    var errorMessage: String?
    var vpnConnectedAt: Date?
    var subscriptionExpire: Date?
    var isAuthenticated: Bool = false
    var isInitialized: Bool = false
    /// When true, UI should present the VPN permission primer instead of
    /// toggling the tunnel. Set by `requestConnect()` on first connect
    /// attempt; UI clears it via `proceedAfterPrimer()` or by dismissing.
    var showPermissionPrimer: Bool = false
    var routingMode: RoutingMode = {
        let raw = UserDefaults(suiteName: AppConstants.appGroupID)?
            .string(forKey: AppConstants.routingModeKey) ?? ""
        return RoutingMode(rawValue: raw) ?? .default
    }()

    /// "Power-user" mode: when ON, the server picker exposes per-protocol
    /// leaves (Hysteria2/TUIC/Direct/via-MSK) and the home pill shows a
    /// subtitle with the active leg. Unlocked via 5-tap on the picker
    /// nav title; sticky for the session, not persisted — a kill+relaunch
    /// returns to the simplified UX.
    var powerModeUnlocked: Bool = false

    /// Last fallback notification message (Russian/English depending on
    /// system locale). Surfaced as a toast over the home view; nil hides it.
    /// Auto-clears after 5s like errorMessage. Set by TrafficHealthMonitor
    /// when it switches the user off a dead leg.
    var fallbackToastMessage: String?

    /// True when the host SwiftUI scene is active (foreground+visible).
    /// Set by MadFrogVPNApp's `.onChange(of: scenePhase)`. The traffic
    /// health monitor reads this so it doesn't probe in the background.
    var isAppActive: Bool = true

    /// Built lazily on first foreground after a connect. Owned here so the
    /// extension's libbox doesn't have to know about it (extension memory
    /// is tight; this lives in main app process).
    @ObservationIgnored
    private var trafficHealthMonitor: TrafficHealthMonitor?

    /// Build-39: server selection moved out of the NetworkExtension's
    /// sing-box `urltest` outbound and into the main app. PathPicker probes
    /// candidate leaves via NWConnection (TCP-only, no HTTP) and picks the
    /// lowest-latency winner — the extension just gets a single leaf via
    /// `selectOutbound("Proxy", leaf)`. See PathPicker.swift header for
    /// rationale (50MB jetsam cap on iOS NE extensions).
    @ObservationIgnored
    private let leafRankingStore = LeafRankingStore()
    @ObservationIgnored
    private lazy var pathPicker = PathPicker(store: leafRankingStore)

    /// Build-35: per-network "this leaf worked here last time" memory.
    /// Kept across the build-39 refactor as a fast-path hint: if PathPicker
    /// has a fresh measurement for the remembered leaf, we skip the full
    /// probe round.
    @ObservationIgnored
    private let legRaceProbe = LegRaceProbe()  // build-39: kept for tests; new code uses pathPicker
    @ObservationIgnored
    private let lastWorkingLegStore = LastWorkingLegStore()
    /// Cached fingerprint of the current network — refreshed at every
    /// connect attempt and at health-probe success.
    @ObservationIgnored
    private var currentNetworkFingerprint: String?

    /// Build-37: single-flight guard for `toggleVPN()`. iOS sometimes delivers
    /// duplicate touch events from a single physical tap (or the user double-
    /// taps), and SwiftUI's `Button` does not debounce. Without this guard, two
    /// taps within the same MainActor hop both pass `vpnManager.isConnected`
    /// and start two parallel connect flows: 2× preconnect race, 2× tunnel
    /// start, then 2× `applyRoutingModeIfLive` + `applyServerSelectionIfLive`,
    /// each spawning its own `selectOutbound` chain. The combined burst (8+
    /// `closeConnections` in 100ms) tears every TLS handshake the user's
    /// browser has in flight — the "то грузило то не грузило" symptom from
    /// 2026-04-26 field test. Stored as nonisolated(unsafe) since `@Observable`
    /// + `@MainActor` + mutable property combo needs the dance.
    @ObservationIgnored
    private var toggleVPNInFlight: Bool = false

    /// Build-37: cancel-then-replace slots for the deferred apply tasks
    /// triggered by `handleStatus(.connected)`. NEVPNStatusDidChange can fire
    /// `.connected` more than once during a single connect cycle (status
    /// observer may re-emit; toggleVPN's `awaitConnectionWithSilentRetry`
    /// also triggers `handleStatus()` directly to belt-and-braces a missed
    /// transition). Without these slots, every duplicate `.connected` queues
    /// another retry-loop that polls `commandClient.isConnected` and fires
    /// the same `selectOutbound` calls when it becomes ready — which is what
    /// caused the 8× `closeConnections` storm in the 2026-04-26 NL field log.
    @ObservationIgnored
    private var pendingApplyTask: Task<Void, Never>?
    @ObservationIgnored
    private var routingApplyTask: Task<Void, Never>?
    @ObservationIgnored
    private var selectionApplyTask: Task<Void, Never>?

    /// Per-country failed-leaf attempts inside a single fallback cascade.
    /// Cleared whenever the user manually selects a server or the cascade
    /// settles back to a working state. Prevents the monitor from cycling
    /// through the same dead leaves forever — once a leaf has failed in
    /// the current sequence we skip it and escalate.
    @ObservationIgnored
    private var deadLeavesInCurrentCascade: Set<String> = []

    /// Country urltest tags that exhausted all their leaves in the current
    /// cascade. Used by the build-33 cascade chain to skip already-tried
    /// countries when escalating to the next-best country. Cleared on
    /// manual user pick or a clean recovery (probe success).
    @ObservationIgnored
    private var deadCountriesInCurrentCascade: Set<String> = []

    /// Hard cap on cascade depth. We try at most `maxCascadeDepth` distinct
    /// countries before falling through to SPB relays — prevents the
    /// monitor from spending the user's battery flailing across every
    /// country when the underlying network is genuinely down.
    private let maxCascadeDepth = 3

    @ObservationIgnored nonisolated(unsafe) private var statusObserver: Any?
    /// Background config refresh task (handleForeground, toggleVPN).
    @ObservationIgnored nonisolated(unsafe) private var refreshTask: Task<Void, Never>?
    /// Server switch reconnect task (selectServer). Separate from refreshTask
    /// so that background config updates don't cancel reconnection.
    @ObservationIgnored nonisolated(unsafe) private var reconnectTask: Task<Void, Never>?

    private var hasInitialized = false

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        refreshTask?.cancel()
        reconnectTask?.cancel()
    }

    func initialize() async {
        // Keychain survives app deletion on iOS — detect fresh install via UserDefaults flag.
        // If onboardingCompleted is not set, treat as fresh install and wipe Keychain.
        let sharedDefaults = UserDefaults(suiteName: AppConstants.appGroupID)
        let onboardingDone = sharedDefaults?.bool(forKey: AppConstants.onboardingCompletedKey) ?? false
        if !onboardingDone && configStore.username != nil {
            AppLogger.app.info("initialize: fresh install detected, clearing stale Keychain data")
            configStore.clear()
        }

        // Fix: if config file is corrupted (missing selector/urltest), delete it
        // so fresh config is fetched from API
        repairConfigIfNeeded()

        // Fix: if cached config is an error response (not a valid sing-box config),
        // clear everything and force re-registration.
        if let cached = configStore.loadConfig(), cached.contains("\"error\""), !cached.contains("\"outbounds\"") {
            AppLogger.app.info("initialize: cached config is error response, clearing all")
            configStore.clear()
        }

        servers = configStore.parseServersFromConfig()
        selectedServerTag = configStore.selectedServerTag
        subscriptionExpire = configStore.subscriptionExpire
        isAuthenticated = configStore.username != nil

        // Build-32 migration: legacy installs may have a leaf tag pinned
        // (e.g. "de-h2-de") because the previous picker wrote leaves
        // directly. The new default UX pins country urltests instead, and
        // a stale leaf pin can leave the user on a dead protocol with no
        // way to recover via the simplified UI. Promote leaf → country
        // exactly once. Power-mode users who deliberately pick a leaf
        // after this migration runs are unaffected.
        AppState.migrateLeafToCountryIfNeeded(
            configStore: configStore,
            servers: servers,
            mirrorTo: { [weak self] newTag in self?.selectedServerTag = newTag }
        )

        do {
            try await vpnManager.load()
            startObservingVPNStatus()
            // Sync initial state: if VPN is already up (e.g. cold start while On Demand
            // reconnected the tunnel), proactively stamp vpnConnectedAt and kick the
            // command client so chips/timers render correctly.
            handleStatus()
        } catch {
            AppLogger.app.error("VPN load failed: \(error)")
        }

        // Mark as initialized BEFORE network calls — prevents black screen when offline.
        // UI can now render immediately with cached data while config refreshes in background.
        hasInitialized = true
        isInitialized = true

        // Refresh config silently on app launch (only if already signed in)
        if configStore.username != nil {
            await silentConfigUpdate()
        }
    }

    /// Build-32 one-shot: rewrite a legacy leaf-tag pin (e.g. `de-h2-de`)
    /// to the country urltest tag the leaf belongs to (`🇩🇪 Германия`).
    ///
    /// Why this exists: build 31 and earlier wrote leaf tags directly into
    /// `selectedServerTag` when the user drilled into a country picker.
    /// Build 32 promotes the country picker to a one-tap flow, and a stale
    /// leaf pin leaves the user with no UI affordance to recover. Country
    /// urltests are also more resilient — they survive a single leg going
    /// dark — which is what we actually want most of the time.
    ///
    /// Idempotent: gates on `migrationLeafToCountryV32Key` in App Group
    /// UserDefaults. Power-mode users who deliberately pick a leaf after
    /// migration ran are unaffected.
    ///
    /// Static so unit tests can drive it with synthetic ServerGroup arrays
    /// without spinning up a full AppState.
    static func migrateLeafToCountryIfNeeded(
        configStore: ConfigStore,
        servers: [ServerGroup],
        defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID),
        mirrorTo: ((String?) -> Void)? = nil
    ) {
        let result = migrateLeafToCountry(
            currentTag: configStore.selectedServerTag,
            servers: servers,
            isMigrated: { defaults?.bool(forKey: AppConstants.migrationLeafToCountryV32Key) ?? false },
            markMigrated: { defaults?.set(true, forKey: AppConstants.migrationLeafToCountryV32Key) }
        )
        guard let newTag = result else { return }
        configStore.selectedServerTag = newTag
        mirrorTo?(newTag)
    }

    /// Pure logic core of `migrateLeafToCountryIfNeeded` — fully unit-testable
    /// without UserDefaults or ConfigStore. Returns the new tag the caller
    /// should persist, or nil if no migration is needed (already migrated,
    /// pinned to non-leaf, or no matching country found). The callbacks
    /// gate the one-shot guard so it remains idempotent across launches.
    static func migrateLeafToCountry(
        currentTag: String?,
        servers: [ServerGroup],
        isMigrated: () -> Bool,
        markMigrated: () -> Void
    ) -> String? {
        if isMigrated() { return nil }
        defer { markMigrated() }

        guard let pinned = currentTag else { return nil }
        guard case .leaf = ServerTagShape(pinned) else { return nil }

        let countryTag: String? = servers
            .flatMap(\.countries)
            .first(where: { $0.serverTags.contains(pinned) })?
            .tag

        guard let countryTag else {
            AppLogger.app.info("migration v32: leaf '\(pinned)' has no matching country, leaving as-is")
            return nil
        }

        AppLogger.app.info("migration v32: leaf '\(pinned)' → country '\(countryTag)'")
        TunnelFileLogger.log("migration v32: leaf '\(pinned)' → country '\(countryTag)'", category: "ui")
        return countryTag
    }

    /// Called when app returns to foreground. Refreshes config in background.
    func handleForeground() async {
        guard hasInitialized, configStore.username != nil else { return }
        AppLogger.app.info("handleForeground: refreshing config in background")
        refreshTask?.cancel()
        refreshTask = Task { await silentConfigUpdate() }
    }

    /// Delete corrupted or outdated config.
    /// Forces re-download from API on next connect.
    private func repairConfigIfNeeded() {
        guard let config = configStore.loadConfig(),
              let data = config.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = json["outbounds"] as? [[String: Any]]
        else { return }

        let hasProxySelector = outbounds.contains {
            ($0["type"] as? String) == "selector" && ($0["tag"] as? String) == "Proxy"
        }

        // Check for deprecated inbound fields (sing-box 1.13 deprecation)
        let inbounds = (json["inbounds"] as? [[String: Any]]) ?? []
        let hasLegacyInbound = inbounds.contains { $0["sniff"] != nil || $0["sniff_override_destination"] != nil }

        // Build-39: only the Proxy selector is required. Pre-build-39 configs
        // also had `urltest` outbounds for "Auto" + per-country grouping;
        // those are gone now (server selection moved into the main app via
        // PathPicker). A fresh build-39 config legitimately has zero urltest
        // outbounds, so don't gate on their presence — that would loop-clear
        // every healthy config.
        if !hasProxySelector || hasLegacyInbound {
            AppLogger.app.info("repairConfigIfNeeded: clearing outdated config (proxy=\(hasProxySelector) legacyInbound=\(hasLegacyInbound))")
            try? FileManager.default.removeItem(at: AppConstants.configFileURL)
            UserDefaults(suiteName: AppConstants.appGroupID)?.removeObject(forKey: AppConstants.startOptionsKey)
        }
    }

    /// Anonymous device registration — the "Continue without account" flow.
    /// Backed by a device-id tied trial; no Apple/email binding. Users who
    /// later want multi-device or restore-on-reinstall can sign in with
    /// Apple from Settings, which links this device to an Apple identity
    /// server-side.
    func signInAnonymous() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        AppLogger.app.info("signInAnonymous: starting device registration")
        TunnelFileLogger.log("signInAnonymous: ENTER", category: "auth")
        do {
            let result = try await apiClient.registerDevice()
            AppLogger.app.info("signInAnonymous: registered as \(result.username)")
            TunnelFileLogger.log("signInAnonymous: registerDevice OK, username=\(result.username) isNew=\(result.isNew ?? false)", category: "auth")
            configStore.accessToken = result.accessToken
            configStore.refreshToken = result.refreshToken
            configStore.username = result.username
            try await fetchAndSaveConfig()
            subscriptionExpire = configStore.subscriptionExpire
            UserDefaults(suiteName: AppConstants.appGroupID)?.set(true, forKey: AppConstants.onboardingCompletedKey)
            isAuthenticated = true
            TunnelFileLogger.log("signInAnonymous: SUCCESS", category: "auth")
        } catch {
            AppLogger.app.error("signInAnonymous: FAILED: \(error.localizedDescription)")
            TunnelFileLogger.log("signInAnonymous: FAILED — \(String(describing: error))", category: "auth")
            errorMessage = String(localized: "onboarding.anon_failed")
        }
    }

    private func fetchAndSaveConfig() async throws {
        guard let username = configStore.username else {
            AppLogger.app.error("fetchAndSaveConfig: no username")
            return
        }
        AppLogger.app.info("fetchAndSaveConfig: fetching for \(username)")

        do {
            try await doFetchAndSave(username: username)
        } catch APIError.unauthorized {
            AppLogger.app.info("fetchAndSaveConfig: 401, attempting token refresh")
            let refreshed = await tryRefreshToken()
            if refreshed {
                try await doFetchAndSave(username: username)
            } else {
                AppLogger.app.info("fetchAndSaveConfig: refresh failed, re-registering device")
                try await reRegisterDevice()
            }
        } catch APIError.serverError(let code) where code == 404 {
            // Backend returns 404 when JWT is valid but user_id is not in DB
            // (DB wiped, migration, soft-delete edge case, etc). Stale creds
            // survive iOS reinstall via Keychain — only re-registering can
            // unstick. Symptom: "404 on fresh install" reports.
            AppLogger.app.info("fetchAndSaveConfig: 404 user_not_found, clearing creds + re-registering")
            configStore.clear()
            try await reRegisterDevice()
            try await doFetchAndSave(username: configStore.username ?? username)
        } catch let error as APIError where isNetworkError(error) {
            AppLogger.app.info("fetchAndSaveConfig: network error, retrying once")
            try await Task.sleep(for: .seconds(2))
            try await doFetchAndSave(username: username)
        }
    }

    private func doFetchAndSave(username: String) async throws {
        let result = try await apiClient.fetchConfig(username: username, accessToken: configStore.accessToken)
        AppLogger.app.info("fetchAndSaveConfig: got config, length=\(result.config.count)")
        try configStore.saveConfig(result.config)
        if result.expire > 0 {
            let expireDate = Date(timeIntervalSince1970: TimeInterval(result.expire))
            configStore.subscriptionExpire = expireDate
            subscriptionExpire = expireDate
            AppLogger.app.info("fetchAndSaveConfig: expire=\(result.expire) (\(expireDate))")
        }
        servers = configStore.parseServersFromConfig()
        AppLogger.app.info("fetchAndSaveConfig: parsed \(self.servers.count) groups, total items=\(self.servers.flatMap(\.items).count)")
        // Warm the ping cache in the background so the server picker shows
        // values instantly the first time the user opens it.
        let allItems = servers.flatMap(\.items)
        Task { [pingService] in await pingService.probe(allItems) }
    }

    private func tryRefreshToken() async -> Bool {
        guard let refreshToken = configStore.refreshToken else { return false }
        do {
            let newAccessToken = try await apiClient.refreshAccessToken(refreshToken)
            configStore.accessToken = newAccessToken
            AppLogger.app.info("tryRefreshToken: success")
            return true
        } catch {
            AppLogger.app.error("tryRefreshToken: failed: \(error.localizedDescription)")
            return false
        }
    }

    private func reRegisterDevice() async throws {
        let result = try await apiClient.registerDevice()
        AppLogger.app.info("reRegisterDevice: registered as \(result.username)")
        configStore.accessToken = result.accessToken
        configStore.refreshToken = result.refreshToken
        configStore.username = result.username
        try await doFetchAndSave(username: result.username)
    }

    private func isNetworkError(_ error: APIError) -> Bool {
        if case .networkError = error { return true }
        return false
    }

    /// Fetch fresh config from API and save. Silently logs errors — never shows them to the user.
    private func silentConfigUpdate() async {
        do {
            try await fetchAndSaveConfig()
            if let config = configStore.loadConfig() {
                UserDefaults(suiteName: AppConstants.appGroupID)?.set(
                    configForStartup() ?? config,
                    forKey: AppConstants.startOptionsKey
                )
            }
        } catch {
            AppLogger.app.error("Config update failed (using cached): \(error.localizedDescription)")
        }
    }

    /// Build the startup JSON for the cached config with the user's current
    /// selection baked in. Returns nil only if the on-disk config can't be
    /// parsed — callers fall back to the raw config in that case.
    private func configForStartup() -> String? {
        let target = configStore.selectedServerTag ?? "Auto"
        return buildConfigWithSelections(chain: chainOrFallback(target: target))
    }

    /// Build a fresh `[LeafCandidate]` from the cached server list. Empty
    /// before `parseServersFromConfig` has populated `servers` (very first
    /// launch / no config) — callers should treat empty as "no probe possible,
    /// fall through to whatever default the config baked in".
    private func leafCandidates() -> [LeafCandidate] {
        guard let proxy = servers.first(where: { $0.type == "selector" && $0.selectable }) else {
            return []
        }
        return proxy.items.compactMap { item in
            guard !item.host.isEmpty, item.port > 0 else { return nil }
            return LeafCandidate(tag: item.tag, host: item.host, port: item.port, type: item.type)
        }
    }

    /// Build-39: synchronous best-guess translator used by sync code paths
    /// (`selectServer`, `configForStartup`) that need a Proxy → leaf chain
    /// without running an async PathPicker probe. Falls through to the
    /// existing `resolveSelectionChain` first; on miss (target is "Auto"
    /// or a country urltest tag — both no longer exist in the new flat
    /// config), maps to the cached-best or alphabetically-first leaf in
    /// the matching country.
    ///
    /// Async paths (`configForStartupWithRace`, `applyServerSelectionIfLive`)
    /// use the full `pathPicker.bestLeaf` which can probe; this helper
    /// only consults `LeafRankingStore` and the parsed candidates so it
    /// stays sync and cheap.
    private func chainOrFallback(target: String) -> [SelectionStep] {
        let chain = resolveSelectionChain(target: target)
        if !chain.isEmpty { return chain }

        let candidates = leafCandidates()
        guard !candidates.isEmpty else { return [] }

        // Power-mode pin (target IS a leaf tag in current candidates).
        if candidates.contains(where: { $0.tag == target }) {
            return [SelectionStep(group: "Proxy", target: target)]
        }

        // Map "Auto" / country label → leaf via cache or alphabetical.
        let countryFilter = PathPicker.countryCode(forSelectedTag: target)
        let pool = candidates.filter { countryFilter == nil || $0.country == countryFilter }
        guard !pool.isEmpty else { return [] }

        // Cache-best from LeafRankingStore (fresh successful entry only).
        let cutoff = Date().addingTimeInterval(-PathPicker.defaultCacheTTL)
        let recent = leafRankingStore.load()
            .filter { $0.measuredAt > cutoff && $0.success }
        let recentByTag = Dictionary(uniqueKeysWithValues: recent.map { ($0.tag, $0) })
        let pickedTag: String = pool.min(by: {
            (recentByTag[$0.tag]?.latencyMs ?? .max)
            < (recentByTag[$1.tag]?.latencyMs ?? .max)
        })?.tag ?? pool.sorted(by: { $0.tag < $1.tag }).first!.tag
        return [SelectionStep(group: "Proxy", target: pickedTag)]
    }

    /// Build the cold-start config. Build-39 return-to-urltest: no pre-connect
    /// TCP probe — we no longer pick a leaf before the tunnel is up. The
    /// config is built around the user's UI selection ("Auto" / country
    /// urltest tag / specific leaf for power-mode), and sing-box's own
    /// urltest groups decide which leaf actually carries traffic, end-to-end
    /// rather than first-hop. This eliminates the false-positive class on
    /// RKN-blocked direct paths (TCP handshake succeeds → Reality data dies)
    /// and removes the need for a custom watchdog.
    ///
    /// Side effects: refreshes `currentNetworkFingerprint` for telemetry.
    private func configForStartupWithRace() async -> String? {
        currentNetworkFingerprint = await NetworkFingerprint.current()
        return configForStartup()
    }

    /// Snapshot the currently-active leaf as "known good". Build-39 records
    /// to PathPicker's ranking store (so subsequent connects bypass the
    /// probe) AND to `LastWorkingLegStore` (per-network preferred hint,
    /// preserved for backwards compat / future use). Called from
    /// TrafficHealthMonitor.onProbeSuccess so we only record
    /// real-world-confirmed legs, not whatever picker's RTT probe
    /// happens to like.
    private func recordWorkingLegToMemory() {
        // PathPicker's currentLeaf is the one we just connected through.
        // The probe-success signal from TrafficHealthMonitor doesn't carry
        // a fresh latency, so re-stamp the stored measurement with `now()`
        // and the existing latency (or 50ms as a fallback) so cache TTL
        // resets on every healthy probe.
        if let activeLeaf = pathPicker.currentLeaf, !activeLeaf.isEmpty {
            let prev = leafRankingStore.load().first(where: { $0.tag == activeLeaf })
            let latencyMs = prev?.latencyMs ?? 50
            pathPicker.recordSuccess(leaf: activeLeaf, latencyMs: latencyMs)
            // Legacy per-network memory — keep populated for future pinning.
            if let fp = currentNetworkFingerprint, let cc = leafCountryCode(activeLeaf) {
                lastWorkingLegStore.set(fingerprint: fp, country: cc, leg: activeLeaf)
            }
        }
    }

    /// Fetch fresh config with a timeout. Falls back to cached config if fetch fails or times out.
    /// Public so the UI refresh button can force a re-fetch when user suspects stale config.
    func refreshConfig(timeout: Duration = .seconds(5)) async {
        AppLogger.app.info("refreshConfig: fetching (timeout=\(timeout))")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.silentConfigUpdate() }
            group.addTask { try? await Task.sleep(for: timeout) }
            _ = await group.next()
            group.cancelAll()
            for await _ in group { }
        }
        AppLogger.app.info("refreshConfig: done")
    }

    // MARK: - Sign In

    /// Sign in by Google ID token received from GoogleSignIn SDK.
    /// Parallel to `signInWithApple` but without a credential wrapper.
    func signInWithGoogle(idToken: String) async {
        AppLogger.app.info("signInWithGoogle: entry, tokenLen=\(idToken.count, privacy: .public)")
        TunnelFileLogger.log("signInWithGoogle: ENTER, tokenLen=\(idToken.count)", category: "auth")
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await apiClient.signInWithGoogle(idToken: idToken)
            AppLogger.app.info("signInWithGoogle: username=\(result.username), isNew=\(result.isNew ?? false)")
            TunnelFileLogger.log("signInWithGoogle: API OK, username=\(result.username) isNew=\(result.isNew ?? false)", category: "auth")
            configStore.accessToken = result.accessToken
            configStore.refreshToken = result.refreshToken
            configStore.username = result.username
            try await fetchAndSaveConfig()
            subscriptionExpire = configStore.subscriptionExpire
            UserDefaults(suiteName: AppConstants.appGroupID)?.set(true, forKey: AppConstants.onboardingCompletedKey)
            isAuthenticated = true
            TunnelFileLogger.log("signInWithGoogle: SUCCESS", category: "auth")
        } catch {
            AppLogger.app.error("signInWithGoogle: failed: \(String(describing: error), privacy: .public)")
            TunnelFileLogger.log("signInWithGoogle: FAILED — \(String(describing: error))", category: "auth")
            errorMessage = String(localized: "onboarding.signin_failed")
        }
    }

    /// Email entry: ask backend to send a magic link. Always resolves to a
    /// "check your email" confirmation in UI, even on rate-limit, because we
    /// don't want to leak which addresses have accounts.
    func requestMagicLink(email: String) async -> Bool {
        TunnelFileLogger.log("requestMagicLink: ENTER", category: "auth")
        errorMessage = nil
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            TunnelFileLogger.log("requestMagicLink: REJECTED — empty email", category: "auth")
            errorMessage = String(localized: "magic.error.invalid_email")
            return false
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await apiClient.requestMagicLink(email: trimmed)
            TunnelFileLogger.log("requestMagicLink: SUCCESS", category: "auth")
            return true
        } catch APIError.serverError(429) {
            TunnelFileLogger.log("requestMagicLink: RATE LIMITED (429)", category: "auth")
            errorMessage = String(localized: "magic.error.rate_limited")
            return false
        } catch {
            AppLogger.app.error("requestMagicLink: failed: \(String(describing: error), privacy: .public)")
            TunnelFileLogger.log("requestMagicLink: FAILED — \(String(describing: error))", category: "auth")
            errorMessage = String(localized: "magic.error.generic")
            return false
        }
    }

    /// Called from MadFrogVPNApp.handleUniversalLink when a /app/signin?token=…
    /// link is opened. Redeems the token and completes auth.
    ///
    /// If the user is already signed in, we skip redeeming so we don't
    /// consume a usable magic token — the link's still valid in their
    /// inbox if they need it on another device. We surface a quick toast
    /// instead so the tap isn't silent.
    func consumeMagicToken(_ token: String) async {
        let wasAuthenticated = isAuthenticated
        AppLogger.app.info("consumeMagicToken: entry, tokenLen=\(token.count, privacy: .public), alreadyAuthenticated=\(wasAuthenticated, privacy: .public)")
        TunnelFileLogger.log("consumeMagicToken: ENTER, tokenLen=\(token.count) alreadyAuth=\(wasAuthenticated)", category: "auth")
        errorMessage = nil
        if wasAuthenticated {
            TunnelFileLogger.log("consumeMagicToken: skip — already authenticated", category: "auth")
            errorMessage = String(localized: "magic.already_signed_in")
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await apiClient.verifyMagicLink(token: token)
            AppLogger.app.info("consumeMagicToken: username=\(result.username), isNew=\(result.isNew ?? false)")
            TunnelFileLogger.log("consumeMagicToken: API OK, username=\(result.username) isNew=\(result.isNew ?? false)", category: "auth")
            configStore.accessToken = result.accessToken
            configStore.refreshToken = result.refreshToken
            configStore.username = result.username
            try await fetchAndSaveConfig()
            subscriptionExpire = configStore.subscriptionExpire
            UserDefaults(suiteName: AppConstants.appGroupID)?.set(true, forKey: AppConstants.onboardingCompletedKey)
            isAuthenticated = true
            TunnelFileLogger.log("consumeMagicToken: SUCCESS", category: "auth")
        } catch {
            AppLogger.app.error("consumeMagicToken: failed: \(String(describing: error), privacy: .public)")
            TunnelFileLogger.log("consumeMagicToken: FAILED — \(String(describing: error))", category: "auth")
            errorMessage = String(localized: "magic.error.invalid_link")
        }
    }

    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async {
        AppLogger.app.info("signInWithApple: entry, hasToken=\(credential.identityToken != nil, privacy: .public), user=\(credential.user, privacy: .public)")
        TunnelFileLogger.log("signInWithApple: ENTER, hasToken=\(credential.identityToken != nil)", category: "auth")
        errorMessage = nil
        guard let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            AppLogger.app.error("signInWithApple: no identity token in credential")
            TunnelFileLogger.log("signInWithApple: FAILED — no identity token in credential", category: "auth")
            errorMessage = String(localized: "onboarding.signin_failed")
            return
        }
        AppLogger.app.info("signInWithApple: got token, len=\(token.count, privacy: .public)")
        TunnelFileLogger.log("signInWithApple: tokenLen=\(token.count), calling backend", category: "auth")

        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await apiClient.signInWithApple(identityToken: token)
            AppLogger.app.info("signInWithApple: username=\(result.username), isNew=\(result.isNew ?? false)")
            TunnelFileLogger.log("signInWithApple: API OK, username=\(result.username) isNew=\(result.isNew ?? false)", category: "auth")
            configStore.accessToken = result.accessToken
            configStore.refreshToken = result.refreshToken
            configStore.username = result.username
            try await fetchAndSaveConfig()
            subscriptionExpire = configStore.subscriptionExpire
            UserDefaults(suiteName: AppConstants.appGroupID)?.set(true, forKey: AppConstants.onboardingCompletedKey)
            isAuthenticated = true
            TunnelFileLogger.log("signInWithApple: SUCCESS", category: "auth")
        } catch {
            AppLogger.app.error("signInWithApple: failed: \(String(describing: error), privacy: .public)")
            TunnelFileLogger.log("signInWithApple: FAILED — \(String(describing: error))", category: "auth")
            errorMessage = String(localized: "onboarding.signin_failed")
        }
    }

    /// Called from Paywall after a successful StoreKit purchase or restore.
    /// Re-fetches the config so `subscriptionExpire` and the `servers` list
    /// reflect the freshly-extended plan.
    func refreshAfterPurchase() async {
        AppLogger.app.info("refreshAfterPurchase: pulling updated config")
        do {
            try await fetchAndSaveConfig()
        } catch {
            AppLogger.app.error("refreshAfterPurchase: \(error.localizedDescription)")
        }
    }

    // MARK: - Account lifecycle

    /// Sign the user out locally. Disconnects VPN, wipes all credentials,
    /// and returns to the onboarding screen. Does not call any backend —
    /// tokens will expire on their own.
    func logout() async {
        AppLogger.app.info("logout: begin")
        if vpnManager.status == .connected || vpnManager.status == .connecting || vpnManager.status == .reasserting {
            vpnManager.disconnect()
            await vpnManager.waitUntilDisconnected(timeout: .seconds(5))
        }
        try? await vpnManager.resetProfile()
        configStore.clear()
        subscriptionExpire = nil
        servers = []
        isAuthenticated = false
        errorMessage = nil
        AppLogger.app.info("logout: done")
    }

    /// Permanently delete the authenticated user's account on the backend,
    /// then perform a local logout. Required by App Store Review 5.1.1(v).
    func deleteAccount() async {
        AppLogger.app.info("deleteAccount: begin")
        guard let token = configStore.accessToken else {
            AppLogger.app.info("deleteAccount: no access token, local-only cleanup")
            await logout()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await apiClient.deleteAccount(accessToken: token)
            AppLogger.app.info("deleteAccount: backend confirmed")
        } catch {
            AppLogger.app.error("deleteAccount: backend failed: \(error.localizedDescription)")
            errorMessage = VPNErrorMapper.humanMessage(error)
            return
        }
        await logout()
    }

    // MARK: - VPN

    /// UI-level entry point for the Connect button. On the very first tap —
    /// when no NETunnelProviderManager has been saved yet — we show a
    /// pre-permission primer instead of triggering the system alert cold.
    /// Once the user has confirmed the primer, `toggleVPN()` is called.
    /// Subsequent taps go straight to `toggleVPN()`.
    func requestToggle() async {
        if !vpnManager.isConnected && !vpnManager.hasInstalledProfile {
            showPermissionPrimer = true
            return
        }
        await toggleVPN()
    }

    /// Called by the primer's Continue button to proceed with the actual
    /// connect — which triggers the iOS permission alert.
    func proceedAfterPrimer() async {
        showPermissionPrimer = false
        await toggleVPN()
    }

    /// Build-36: wait up to 18s for the tunnel; on `.timedOut`, silently
    /// disconnects, sleeps 1s, reconnects, and waits 18s again. Only the
    /// second timeout surfaces. Buys a near-100% success rate against the
    /// build-35 watchdog regression where libbox cold-start on LTE could
    /// take 9-15s and the 10s watchdog killed connects ~50ms before success.
    /// Worst-case latency before a real error: ~40s.
    private func awaitConnectionWithSilentRetry(config: String?) async -> VPNManager.ConnectOutcome {
        let first = await vpnManager.waitUntilConnected(timeout: .seconds(18))
        guard case .timedOut = first else { return first }
        TunnelFileLogger.log("toggleVPN: watchdog 18s timeout — silent retry", category: "ui")
        vpnManager.disconnect()
        await vpnManager.waitUntilDisconnected(timeout: .seconds(3))
        try? await Task.sleep(for: .seconds(1))
        do {
            try await vpnManager.connect(configJSON: config)
        } catch {
            TunnelFileLogger.log("toggleVPN: silent retry connect FAILED: \(error)", category: "ui")
            return .failed
        }
        let second = await vpnManager.waitUntilConnected(timeout: .seconds(18))
        if case .timedOut = second {
            TunnelFileLogger.log("toggleVPN: watchdog 18s timeout — second time, giving up", category: "ui")
        }
        return second
    }

    func toggleVPN() async {
        // Build-37: single-flight. See `toggleVPNInFlight` doc.
        guard !toggleVPNInFlight else {
            TunnelFileLogger.log("toggleVPN: ignored — already in flight (duplicate tap)", category: "ui")
            return
        }
        toggleVPNInFlight = true
        defer { toggleVPNInFlight = false }

        TunnelFileLogger.log("toggleVPN: begin, isConnected=\(vpnManager.isConnected)", category: "ui")
        Haptics.impact(.medium)
        if vpnManager.isConnected {
            commandClient.disconnect()
            vpnManager.disconnect()
            refreshTask?.cancel()
            refreshTask = Task { await silentConfigUpdate() }
            TunnelFileLogger.log("toggleVPN: disconnect requested", category: "ui")
            return
        }

        // If we have a cached config — start the tunnel immediately and refresh
        // in the background for next time. Only block on refresh when there is
        // no cache at all (first launch, offline).
        if configStore.hasConfig() {
            TunnelFileLogger.log("toggleVPN: have cached config, running preconnect race + building", category: "ui")
            let config: String? = await configForStartupWithRace() ?? configStore.loadConfig()
            TunnelFileLogger.log("toggleVPN: config built, running preflight probe", category: "ui")

            // Fail-fast preflight: probe each outbound's TCP endpoint before
            // committing to a 10s watchdog. This catches "all servers dead"
            // in ~2s and gives the user a specific, actionable error instead
            // of a generic "server rejected" after 30 seconds of silence.
            switch await preflightProbe() {
            case .ok, .skipped:
                break
            case .allDead:
                TunnelFileLogger.log("toggleVPN: preflight — all servers unreachable", category: "ui")
                errorMessage = L10n.Error.allServersUnreachable
                return
            case .selectedDead(let name):
                TunnelFileLogger.log("toggleVPN: preflight — selected '\(name)' unreachable", category: "ui")
                errorMessage = L10n.Error.selectedUnreachable(name)
                return
            }

            TunnelFileLogger.log("toggleVPN: preflight OK, calling vpnManager.connect", category: "ui")

            do {
                try await vpnManager.connect(configJSON: config)
                TunnelFileLogger.log("toggleVPN: vpnManager.connect returned OK", category: "ui")
            } catch {
                TunnelFileLogger.log("toggleVPN: vpnManager.connect FAILED: \(error)", category: "ui")
                errorMessage = VPNErrorMapper.humanMessage(error)
                return
            }

            // Watchdog: the tunnel must reach .connected within 18s, with
            // one silent retry on timeout. Build-36: libbox cold-start on
            // LTE can take 9-15s; the previous 10s watchdog killed connects
            // ~50ms before success. Preflight already confirmed at least one
            // outbound is network-reachable, so non-timeout failure modes
            // (Reality handshake mismatch, bad UUID) still surface fast.
            let outcome = await awaitConnectionWithSilentRetry(config: config)
            switch outcome {
            case .connected:
                Haptics.notify(.success)
                // Belt-and-braces: NEVPNStatusDidChange notifications can arrive
                // while AppState's MainActor task is busy (toggleVPN is itself
                // running on @MainActor), so the observer-driven handleStatus
                // call may have hit .connecting and missed the .connected
                // transition. Force-stamp here so the timer always starts on
                // first connect (without this, the chip stayed blank until the
                // user backgrounded + foregrounded the app).
                handleStatus()
                break
            case .failed:
                TunnelFileLogger.log("toggleVPN: watchdog — extension rejected connection", category: "ui")
                vpnManager.disconnect()
                errorMessage = L10n.Error.serverRejected
                return
            case .permissionDenied:
                TunnelFileLogger.log("toggleVPN: watchdog — permission denied", category: "ui")
                vpnManager.disconnect()
                errorMessage = VPNErrorMapper.permissionMissing
                return
            case .timedOut:
                vpnManager.disconnect()
                errorMessage = VPNErrorMapper.watchdogTimeout
                return
            }

            // Delay background refresh — if we fire immediately, URLSession
            // competes with the tunnel that's still coming up and iOS sometimes
            // stalls the main queue waiting on network reachability.
            refreshTask?.cancel()
            refreshTask = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await silentConfigUpdate()
            }
            return
        }

        // No cached config: must fetch before we can connect.
        isLoading = true
        defer { isLoading = false }
        await refreshConfig(timeout: .seconds(5))

        guard configStore.hasConfig() else {
            errorMessage = L10n.Error.noConfig
            return
        }

        let config: String? = configForStartup() ?? configStore.loadConfig()

        // Same fail-fast preflight as the cached-config path above.
        switch await preflightProbe() {
        case .ok, .skipped:
            break
        case .allDead:
            errorMessage = L10n.Error.allServersUnreachable
            return
        case .selectedDead(let name):
            errorMessage = L10n.Error.selectedUnreachable(name)
            return
        }

        do {
            try await vpnManager.connect(configJSON: config)
        } catch {
            errorMessage = VPNErrorMapper.humanMessage(error)
            return
        }

        let outcome = await awaitConnectionWithSilentRetry(config: config)
        switch outcome {
        case .connected:
            Haptics.notify(.success)
            return
        case .failed:
            vpnManager.disconnect()
            Haptics.notify(.error)
            errorMessage = L10n.Error.serverRejected
        case .permissionDenied:
            vpnManager.disconnect()
            Haptics.notify(.error)
            errorMessage = VPNErrorMapper.permissionMissing
        case .timedOut:
            vpnManager.disconnect()
            Haptics.notify(.error)
            errorMessage = VPNErrorMapper.watchdogTimeout
        }
    }

    // MARK: - Preflight probe

    private enum PreflightOutcome {
        case ok
        case allDead
        case selectedDead(name: String)
        case skipped
    }

    /// Parallel TCP probe of the outbounds in the current config. Runs with a
    /// 2-second budget per target (PingService default). Returns fast:
    /// `.ok` if at least one outbound is reachable; `.allDead` if none are;
    /// `.selectedDead` if the user picked a specific server and *that* one
    /// is unreachable (even if others are up); `.skipped` if we have no
    /// parsed servers yet (cold start / no config).
    private func preflightProbe() async -> PreflightOutcome {
        // UDP-only outbounds (Hysteria2, TUIC) can't be validated with a TCP
        // handshake — the server only listens on UDP, so probeTCP always
        // times out even when the outbound is healthy. Skip them: if the
        // user explicitly picked a UDP-only server we trust it; if Auto,
        // they count as "alive" alongside any reachable TCP outbound.
        let udpOnlyTypes: Set<String> = ["hysteria2", "tuic"]

        let items: [ServerItem] = servers
            .flatMap { $0.items }
            .filter { !$0.host.isEmpty && $0.port > 0 }
        guard !items.isEmpty else { return .skipped }

        let selectedTag = configStore.selectedServerTag
        let targets: [ServerItem]
        if let tag = selectedTag {
            targets = items.filter { $0.tag == tag }
        } else {
            targets = items
        }
        guard !targets.isEmpty else { return .skipped }

        // User picked a UDP-only server — skip probe, trust it.
        if selectedTag != nil, targets.allSatisfy({ udpOnlyTypes.contains($0.type) }) {
            return .ok
        }

        let tcpTargets = targets.filter { !udpOnlyTypes.contains($0.type) }
        let hasUDPTarget = targets.contains { udpOnlyTypes.contains($0.type) }

        let results: [(String, Int)] = await withTaskGroup(of: (String, Int).self) { group in
            for target in tcpTargets {
                group.addTask {
                    let ms = await PingService.probeTCP(host: target.host, port: target.port, timeout: 2.0)
                    return (target.tag, ms)
                }
            }
            var out: [(String, Int)] = []
            for await r in group { out.append(r) }
            return out
        }

        let anyAlive = results.contains { $0.1 > 0 } || hasUDPTarget
        if anyAlive { return .ok }

        if selectedTag != nil, let dead = targets.first {
            return .selectedDead(name: dead.tag)
        }
        return .allDead
    }

    func selectServer(groupTag: String, serverTag: String) {
        selectServer(groupTag: groupTag, serverTag: serverTag, clearCascade: true)
    }

    /// Internal entry point — `clearCascade: false` is used by the
    /// fallback chain so the dead-leaves set we just appended to isn't
    /// wiped when we hop to the next leaf.
    private func selectServer(groupTag: String, serverTag: String, clearCascade: Bool) {
        let previousTag = configStore.selectedServerTag
        let isAuto = serverTag == "Auto"
        let newTag: String? = isAuto ? nil : serverTag
        configStore.selectedServerTag = newTag
        selectedServerTag = newTag  // @Observable mirror for SwiftUI

        // Manual pick clears the cascade history and gives the new leg
        // a grace window before the health monitor probes again — sing-box
        // needs a moment to settle. Fallback callers pass clearCascade=false
        // so the dead-leaf and dead-country sets survive the hop.
        if clearCascade {
            deadLeavesInCurrentCascade.removeAll()
            deadCountriesInCurrentCascade.removeAll()
        }
        trafficHealthMonitor?.suspendForManualSwitch()

        // Persist the full multi-step selection into the cached startOptions
        // immediately, regardless of whether the tunnel is currently up. This
        // ensures a cold-start connect reads the right selector defaults
        // rather than falling back to "Auto"/"direct" and routing through
        // the wrong country.
        let persistTarget = isAuto ? "Auto" : serverTag
        if let persisted = buildConfigWithSelections(chain: chainOrFallback(target: persistTarget)) {
            UserDefaults(suiteName: AppConstants.appGroupID)?.set(persisted, forKey: AppConstants.startOptionsKey)
        }
        TunnelFileLogger.log("selectServer ENTER: groupTag='\(groupTag)' serverTag='\(serverTag)' prev='\(previousTag ?? "Auto")' connected=\(vpnManager.isConnected) cmdClientConnected=\(commandClient.isConnected)", category: "ui")
        // Dump current servers tree so we can verify the tag we got from
        // the UI is one sing-box actually knows about.
        for g in servers {
            let items = g.items.map { $0.tag }.joined(separator: ", ")
            TunnelFileLogger.log("  group tag='\(g.tag)' type=\(g.type) selectable=\(g.selectable) items=[\(items)]", category: "ui")
        }

        // Update local servers array so UI reflects the change immediately
        for i in servers.indices {
            if servers[i].items.contains(where: { $0.tag == serverTag }) {
                servers[i] = ServerGroup(
                    id: servers[i].id, tag: servers[i].tag, type: servers[i].type,
                    selected: serverTag, items: servers[i].items, selectable: servers[i].selectable,
                    hasAuto: servers[i].hasAuto, countries: servers[i].countries
                )
            }
        }

        let effectiveNew = isAuto ? nil : serverTag
        let tagChanged = previousTag != effectiveNew
        guard vpnManager.isConnected else {
            AppLogger.app.info("selectServer: skipped (not connected), tag persisted")
            return
        }

        // Resolve the full selection chain needed to route Proxy → user's
        // choice. In the 2026-04-24+ config layout, the Proxy selector only
        // references country urltests ("🇳🇱 Нидерланды", …) and "Auto" —
        // never leaf outbounds directly. A leaf tag like "nl-direct-nl2"
        // therefore needs TWO Clash API calls:
        //   1) selectOutbound(<country urltest>, leafTag)   // force urltest pick
        //   2) selectOutbound("Proxy", <country urltest>)   // route Proxy here
        //
        // A country urltest tag (e.g. "🇳🇱 Нидерланды") needs only step 2.
        // "Auto" needs only step 2 with target="Auto".
        let selectorTarget = isAuto ? "Auto" : serverTag
        let chain = chainOrFallback(target: selectorTarget)
        guard !chain.isEmpty else {
            AppLogger.app.error("selectServer: could not resolve selection chain for '\(serverTag)'")
            return
        }

        // Rebuild config JSON with every Clash-API-equivalent change applied
        // inline, so a cold-start tunnel reads the right defaults without
        // depending on the selector API being hit post-boot.
        let updatedConfig = buildConfigWithSelections(chain: chain) ?? configStore.loadConfig()
        AppLogger.app.info("selectServer: chain=\(chain.map { "\($0.group)→\($0.target)" }.joined(separator: " / "))")

        if tagChanged, let updatedConfig {
            UserDefaults(suiteName: AppConstants.appGroupID)?.set(updatedConfig, forKey: AppConstants.startOptionsKey)
        }

        // Fast path: live tunnel — re-pick the leaf via PathPicker for the
        // new selection and push it. Build-39: replaces the old chain-walk +
        // forceUrlTestEverywhere combo. With country urltests gone from the
        // config, the entire selection is a single Clash API call.
        if commandClient.isConnected {
            applyServerSelectionIfLive()
            return
        }

        // Fallback: tunnel up but command client not ready. Only reconnect
        // when the tag actually changed — a same-tag tap with a dead client
        // is nothing to do.
        guard tagChanged, let updatedConfig else { return }
        TunnelFileLogger.log("selectServer: FALLBACK reconnect (commandClient not ready)", category: "ui")
        reconnectTask?.cancel()
        reconnectTask = Task {
            commandClient.disconnect()
            vpnManager.disconnect()
            await vpnManager.waitUntilDisconnected(timeout: .seconds(5))
            guard !Task.isCancelled else { return }
            try? await vpnManager.connect(configJSON: updatedConfig)
        }
    }

    /// A single (group, target) step to apply via Clash API selectOutbound.
    /// Internal (not private) so `ProxyChainResolverTests` can construct
    /// expected chains without pulling in a full AppState fixture.
    struct SelectionStep: Equatable {
        let group: String
        let target: String
    }

    /// Walk the current config's outbound graph and produce the ordered list
    /// of selectOutbound calls needed to route Proxy → `target`.
    private func resolveSelectionChain(target: String) -> [SelectionStep] {
        guard let config = configStore.loadConfig(),
              let data = config.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = json["outbounds"] as? [[String: Any]]
        else { return [] }
        return Self.resolveChain(target: target, outbounds: outbounds)
    }

    /// Pure-function core of selection resolution — exposed `internal`
    /// for unit tests. Takes a parsed sing-box outbounds array (straight
    /// from `JSONSerialization`) and returns the ordered selectOutbound
    /// steps. No I/O, no actor isolation, deterministic.
    ///
    /// Call ordering inside the returned chain matters: urltest/selector
    /// leaf pin comes first so Proxy's final hop lands on a pinned leaf
    /// rather than the urltest's pre-pin RTT pick.
    ///
    /// `nonisolated` because AppState is `@Observable` + @MainActor
    /// (implicit from actor-isolated init) — without the override, test
    /// code from background queues / XCTest sync contexts can't call it.
    nonisolated static func resolveChain(target: String, outbounds: [[String: Any]]) -> [SelectionStep] {
        // Index (type, members) by tag.
        var typeByTag: [String: String] = [:]
        var membersByTag: [String: [String]] = [:]
        for ob in outbounds {
            guard let tag = ob["tag"] as? String,
                  let type = ob["type"] as? String else { continue }
            typeByTag[tag] = type
            if let members = ob["outbounds"] as? [String] {
                membersByTag[tag] = members
            }
        }

        // Helper: is `target` reachable via any Proxy member? Include Auto
        // here — Case 3 below legitimately wants to use Auto as a fallback
        // when a leaf exists only there. Excluding Auto from reachability
        // caused valid leaves-only-in-Auto to return an empty chain before
        // Case 3 even ran.
        func isReachableFromProxy() -> Bool {
            for member in membersByTag["Proxy"] ?? [] {
                if membersByTag[member]?.contains(target) == true { return true }
            }
            return false
        }

        guard membersByTag["Proxy"]?.contains(target) == true ||
              isReachableFromProxy()
        else {
            // Target isn't anywhere under Proxy — caller passed a stale tag.
            return []
        }

        // Case 1: target is a direct member of Proxy (Auto, country urltest,
        // or — post-2026-04-25 — an individual leaf added as Proxy child so
        // manual leaf overrides can be pinned by the Clash API).
        if membersByTag["Proxy"]?.contains(target) == true {
            return [SelectionStep(group: "Proxy", target: target)]
        }

        // Case 2: target is a leaf nested inside a urltest OR selector that
        // IS a direct member of Proxy. Prefer a specific country group over
        // the meta-"Auto" urltest — Auto contains every leaf, so it would
        // match first alphabetically and steal the routing from the user's
        // deliberate country pick. Both urltest and selector parents are
        // accepted (whitelist-bypass is a selector, country groups are
        // urltests).
        for member in membersByTag["Proxy"] ?? [] {
            guard member != "Auto" else { continue }
            let memberType = typeByTag[member] ?? ""
            guard (memberType == "urltest" || memberType == "selector"),
                  membersByTag[member]?.contains(target) == true
            else { continue }
            return [
                SelectionStep(group: member, target: target),
                SelectionStep(group: "Proxy", target: member),
            ]
        }

        // No country group claims this leaf. Last resort: fall back to Auto
        // (only if Auto happens to contain it). Still better than returning
        // an empty chain and leaving Proxy pinned to whatever it was.
        if typeByTag["Auto"] == "urltest",
           membersByTag["Auto"]?.contains(target) == true {
            return [
                SelectionStep(group: "Auto", target: target),
                SelectionStep(group: "Proxy", target: "Auto"),
            ]
        }

        return []
    }

    /// Apply every step from `chain` to the on-disk config's `default`
    /// fields and return the serialized JSON. Falls back to returning nil on
    /// parse error so callers keep using the unchanged config from disk.
    ///
    /// Note: sing-box `urltest` outbounds don't honour a `default` field —
    /// only live selectOutbound pins them. Config persistence is therefore
    /// for selector defaults only; urltest state is reapplied every reload
    /// by `applyServerSelectionIfLive`.
    private func buildConfigWithSelections(chain: [SelectionStep]) -> String? {
        guard let config = configStore.loadConfig(),
              let data = config.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var outbounds = json["outbounds"] as? [[String: Any]]
        else { return nil }

        // Apply default-field updates only for `selector` types. urltest has
        // no `default` field in the sing-box schema — persisted pick won't
        // survive a restart; that's what applyServerSelectionIfLive is for.
        for step in chain {
            for i in outbounds.indices {
                guard outbounds[i]["tag"] as? String == step.group,
                      outbounds[i]["type"] as? String == "selector"
                else { continue }
                outbounds[i]["default"] = step.target
            }
        }

        json["outbounds"] = outbounds
        guard let out = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: out, encoding: .utf8)
        else { return nil }
        return str
    }

    /// Re-applies the persisted server selection to the live tunnel. Called from
    /// handleStatus(.connected) so that a cold-start tunnel whose sing-box Proxy
    /// selector booted on a stale default gets forced onto the user's real pick.
    ///
    /// Build-39 return-to-urltest: we no longer pick a *leaf* and pin Proxy to
    /// it. The user's pick is a UI label ("Auto" / "🇩🇪 Германия" / specific
    /// leaf for power-mode), and `resolveSelectionChain` produces the chain of
    /// `selectOutbound` calls that route Proxy → that label. For Auto and
    /// country urltest groups the chain is a single step that hands control
    /// to sing-box's own urltest — sing-box probes each leaf end-to-end and
    /// picks the lowest-latency *working* one, automatically failing over
    /// when a leaf goes dead. Build-38's pre-connect TCP probe and bytes-flow
    /// watchdog were re-implementing what sing-box already does correctly,
    /// just worse — TCP probe is a false-positive on RKN-blocked paths
    /// (handshake succeeds, Reality data dies), and bytes-flow watchdog read
    /// global counters that mixed Proxy traffic with native LTE direct traffic.
    ///
    /// Why retry: `commandClient` binds to the extension's unix socket AFTER
    /// the tunnel reaches `.connected`. Without retry the apply races the
    /// socket bind and `Proxy` keeps its fresh-config default. Retry 500ms ×
    /// 10 = 5s budget covers the worst observed bind delay (LTE cold-start,
    /// ~700ms).
    private func applyServerSelectionIfLive() {
        let selectedTag = configStore.selectedServerTag ?? "Auto"
        // Build-37: cancel-then-replace. See `selectionApplyTask` doc.
        selectionApplyTask?.cancel()
        selectionApplyTask = Task { [weak self] in
            guard let self else { return }

            let chain = self.resolveSelectionChain(target: selectedTag)
            guard !chain.isEmpty else {
                TunnelFileLogger.log("applyServerSelectionIfLive: empty chain for '\(selectedTag)' — keeping baked-in default", category: "ui")
                return
            }
            let chainStr = chain.map { "\($0.group)→\($0.target)" }.joined(separator: " / ")

            for attempt in 1...10 {
                if Task.isCancelled { return }
                if self.commandClient.isConnected {
                    if attempt > 1 {
                        TunnelFileLogger.log("applyServerSelectionIfLive: cmdClient ready after \(attempt * 500)ms, applying chain=\(chainStr)", category: "ui")
                    } else {
                        TunnelFileLogger.log("applyServerSelectionIfLive: applying chain=\(chainStr)", category: "ui")
                    }
                    for step in chain {
                        self.commandClient.selectOutbound(groupTag: step.group, outboundTag: step.target)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            TunnelFileLogger.log("applyServerSelectionIfLive: cmdClient still not connected after 5s, giving up", category: "ui")
        }
    }

    /// Legacy single-selector lookup. Still used by cold-start paths
    /// (`vpnManager.connect` load from disk) where we only need the Proxy
    /// selector's default updated, not the full multi-step chain.
    private func buildConfigWithSelector(_ serverTag: String) -> (config: String, selectorTag: String)? {
        guard let config = configStore.loadConfig(),
              let data = config.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var outbounds = json["outbounds"] as? [[String: Any]]
        else {
            AppLogger.app.error("buildConfigWithSelector: failed to load/parse config")
            return nil
        }

        var modifiedSelectorTag: String?
        for i in outbounds.indices {
            if outbounds[i]["type"] as? String == "selector" {
                let selectorTag = outbounds[i]["tag"] as? String ?? "unknown"
                let members = outbounds[i]["outbounds"] as? [String] ?? []
                if members.contains(serverTag) {
                    outbounds[i]["default"] = serverTag
                    modifiedSelectorTag = selectorTag
                    AppLogger.app.info("buildConfigWithSelector: selector '\(selectorTag)' → '\(serverTag)'")
                }
            }
        }

        guard let selectorTag = modifiedSelectorTag else {
            AppLogger.app.error("buildConfigWithSelector: no selector contains '\(serverTag)'")
            return nil
        }

        json["outbounds"] = outbounds

        guard let updatedData = try? JSONSerialization.data(withJSONObject: json),
              let updatedConfig = String(data: updatedData, encoding: .utf8)
        else {
            AppLogger.app.error("buildConfigWithSelector: failed to serialize updated config")
            return nil
        }

        return (updatedConfig, selectorTag)
    }

    // MARK: - Routing mode

    /// Persists the routing mode and, if the command client is live, flips
    /// the three selectors ("RU Traffic", "Blocked Traffic", "Default Route")
    /// over the libbox unix socket. No reconnect — sing-box applies the switch
    /// in place. When the tunnel is down, only persistence happens; the mode
    /// is re-applied from `handleStatus` once the command client reconnects.
    func setRoutingMode(_ mode: RoutingMode) {
        routingMode = mode
        UserDefaults(suiteName: AppConstants.appGroupID)?
            .set(mode.rawValue, forKey: AppConstants.routingModeKey)
        TunnelFileLogger.log("setRoutingMode: \(mode.rawValue), cmdClient=\(commandClient.isConnected)", category: "ui")
        Haptics.selection()
        applyRoutingModeIfLive(mode)
    }

    private func applyRoutingModeIfLive(_ mode: RoutingMode) {
        // Retry with backoff: commandClient binds to the extension's unix
        // socket after the tunnel is up, and that's racy. If we miss the
        // window, selectors keep their default-config state (direct for
        // Default Route) and Full VPN silently degrades to Smart-like
        // behaviour — exactly the bug users see when whoer.net shows the
        // real IP. Retry every 500ms for 5s.
        guard commandClient.isConnected else {
            TunnelFileLogger.log("applyRoutingMode: cmdClient not connected, scheduling retry for \(mode.rawValue)", category: "ui")
            // Build-37: cancel-then-replace. See `routingApplyTask` doc.
            routingApplyTask?.cancel()
            routingApplyTask = Task { [weak self] in
                for attempt in 1...10 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if Task.isCancelled { return }
                    guard let self else { return }
                    if self.commandClient.isConnected {
                        TunnelFileLogger.log("applyRoutingMode: cmdClient ready after \(attempt * 500)ms, applying \(mode.rawValue)", category: "ui")
                        for (selector, target) in mode.selectorTargets {
                            self.commandClient.selectOutbound(groupTag: selector, outboundTag: target)
                        }
                        return
                    }
                }
                TunnelFileLogger.log("applyRoutingMode: cmdClient still not connected after 5s, giving up", category: "ui")
            }
            return
        }
        TunnelFileLogger.log("applyRoutingMode: applying \(mode.rawValue) via \(mode.selectorTargets.count) selectors", category: "ui")
        for (selector, target) in mode.selectorTargets {
            commandClient.selectOutbound(groupTag: selector, outboundTag: target)
        }
    }

    // MARK: - Status

    private func startObservingVPNStatus() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleStatus() }
        }
    }

    private func handleStatus() {
        TunnelFileLogger.log("handleStatus: vpn status=\(vpnManager.status.rawValue)", category: "ui")
        let sharedDefaults = UserDefaults(suiteName: AppConstants.appGroupID)

        switch vpnManager.status {
        case .connected:
            if vpnConnectedAt == nil {
                // Restore from UserDefaults if the app was relaunched while
                // the tunnel was still up (On Demand / background relaunch).
                // Otherwise stamp now and persist so the session chip survives
                // app lifecycle transitions.
                let key = AppConstants.vpnConnectedAtKey
                if let ts = UserDefaults(suiteName: AppConstants.appGroupID)?.double(forKey: key), ts > 0 {
                    vpnConnectedAt = Date(timeIntervalSince1970: ts)
                } else {
                    let now = Date()
                    vpnConnectedAt = now
                    UserDefaults(suiteName: AppConstants.appGroupID)?
                        .set(now.timeIntervalSince1970, forKey: key)
                }
            }
            if !commandClient.isConnected { commandClient.connect() }
            // Clear the user-stopped flag on successful connection
            sharedDefaults?.removeObject(forKey: AppConstants.userStoppedVPNKey)
            // Re-apply the user's routing mode AND server selection after a
            // (re)connect. commandClient takes a moment to bind after connect()
            // above — defer one hop so selectOutbound has a live socket to talk
            // to. Server selection must be re-asserted because sing-box may
            // have resolved Proxy to a different default than configStore.
            let mode = routingMode
            // Build-37: cancel-then-replace. NEVPNStatusDidChange may emit
            // `.connected` more than once per cycle; without this guard each
            // emit queues another apply pass that bombards `selectOutbound`
            // (which itself tears in-flight TLS).
            pendingApplyTask?.cancel()
            pendingApplyTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
                self?.applyRoutingModeIfLive(mode)
                self?.applyServerSelectionIfLive()
            }
            startTrafficHealthMonitorIfEligible()
        case .disconnected, .invalid:
            vpnConnectedAt = nil
            UserDefaults(suiteName: AppConstants.appGroupID)?.removeObject(forKey: AppConstants.vpnConnectedAtKey)
            if commandClient.isConnected { commandClient.disconnect() }
            trafficHealthMonitor?.stop()
            deadLeavesInCurrentCascade.removeAll()
            deadCountriesInCurrentCascade.removeAll()
            // Check if the PacketTunnel extension signaled a user-initiated stop
            // (from iOS Settings toggle). If so, disable On Demand to prevent auto-reconnect.
            let userStoppedVPN = sharedDefaults?.bool(forKey: AppConstants.userStoppedVPNKey) ?? false
            if userStoppedVPN {
                sharedDefaults?.removeObject(forKey: AppConstants.userStoppedVPNKey)
                AppLogger.app.info("handleStatus: user stopped VPN from Settings, disabling On Demand")
                Task { await vpnManager.disableOnDemand() }
            }
        default: break
        }
    }

    // MARK: - Traffic health monitor + fallback chain

    /// Hook called by MadFrogVPNApp on `scenePhase` change.
    /// Build-39: gate removed from monitor lifetime — see
    /// `startTrafficHealthMonitorIfEligible`. We still observe the
    /// transition because:
    ///   1. Coming back to foreground is the canonical "user noticed
    ///      something stalled" moment, so we drain the extension's
    ///      stall-signal flag and immediately fire fallback if needed.
    ///   2. UI affordances (the stale-error banner) still need the
    ///      foreground edge.
    func handleScenePhaseActive(_ active: Bool) {
        let wasActive = isAppActive
        isAppActive = active
        TunnelFileLogger.log("scene phase: active=\(active)", category: "ui")
        if active && !wasActive {
            // Build-38: clear stale error banner from a previous foreground
            // session for not-yet-signed-in users. AppState survives
            // background→foreground unchanged, so an errorMessage set during
            // a failed sign-in attempt yesterday would otherwise still be
            // showing over OnboardingView today — symptom user reported as
            // «не сразу вошло» in the 2026-04-26 build 36 field test.
            // Authenticated users see status/connection errors here that
            // are still meaningful, so leave those alone.
            if !isAuthenticated {
                errorMessage = nil
            }
            startTrafficHealthMonitorIfEligible()
            // Build-39: drain the extension's stall flag. If the extension
            // detected a stall while we were backgrounded, run the fallback
            // synchronously now so the very first user interaction (Safari
            // tap, refresh) lands on a working leg.
            Task { [weak self] in
                await self?.handleExtensionStallSignalIfAny()
            }
        }
    }

    /// Build-39: read the `AppConstants.tunnelStallRequestedAtKey` flag
    /// the PacketTunnel extension's `TunnelStallProbe` writes when it
    /// detects 2 consecutive captive-portal probe misses. If a request is
    /// newer than the last one we serviced, run `performFallbackForCurrentLeg`
    /// and stamp the serviced timestamp so we don't re-fire.
    func handleExtensionStallSignalIfAny() async {
        guard let defaults = UserDefaults(suiteName: AppConstants.appGroupID) else { return }
        let requestedAt = defaults.double(forKey: AppConstants.tunnelStallRequestedAtKey)
        guard requestedAt > 0 else { return }
        let servicedAt = defaults.double(forKey: AppConstants.tunnelStallServicedAtKey)
        guard requestedAt > servicedAt else { return }
        guard vpnManager.isConnected else { return }

        TunnelFileLogger.log("ext-stall: signal received (requestedAt=\(requestedAt) servicedAt=\(servicedAt)), invoking fallback", category: "ui")
        await performFallbackForCurrentLeg()
        defaults.set(Date().timeIntervalSince1970, forKey: AppConstants.tunnelStallServicedAtKey)
    }

    private func startTrafficHealthMonitorIfEligible() {
        // Lazy build. The monitor's lifetime tracks AppState so a single
        // instance survives across connect/disconnect cycles.
        if trafficHealthMonitor == nil {
            trafficHealthMonitor = TrafficHealthMonitor(dependencies: .init(
                isVPNConnected: { [weak self] in self?.vpnManager.isConnected ?? false },
                isCommandClientConnected: { [weak self] in self?.commandClient.isConnected ?? false },
                isAppActive: { [weak self] in self?.isAppActive ?? false },
                isUserEnabled: { [weak self] in self?.configStore.autoRecoverEnabled ?? true },
                probe: { url, timeout in
                    await HealthProbeURLSession.probe(url: url, timeout: timeout)
                },
                onStallDetected: { [weak self] in
                    await self?.performFallbackForCurrentLeg()
                },
                onProbeSuccess: { [weak self] in
                    await MainActor.run {
                        self?.recordWorkingLegToMemory()
                    }
                    // Build-39: every successful main-app probe also drains
                    // the extension stall flag. Catches the case where
                    // background→foreground happened so fast we missed the
                    // scenePhase event but extension had flagged a stall.
                    await self?.handleExtensionStallSignalIfAny()
                },
                log: { msg in
                    TunnelFileLogger.log(msg, category: "ui")
                }
            ))
        }
        // Build-39: isAppActive gate removed. The PacketTunnel extension
        // hosts an identical probe (TunnelStallProbe) that runs even while
        // iOS suspends the main app — exactly when stall detection actually
        // matters (user is in Safari, MadFrog backgrounded). This main-app
        // monitor is now defense-in-depth for the foreground window plus a
        // place to react to the extension's cross-process stall flag.
        guard configStore.autoRecoverEnabled, vpnManager.isConnected else { return }
        trafficHealthMonitor?.start()
    }

    /// Smart fallback chain (build-33 cascade). Strategy modelled on what
    /// the user actually expects: stay close to their original choice for
    /// as long as possible, only escalating away from it when all options
    /// in that scope are exhausted. Order:
    ///
    ///   1. **Same country, different leaf** — try the next not-yet-tried
    ///      leaf inside the pinned country. Silent, no toast.
    ///   2. **Country exhausted** — mark country dead in the cascade, send
    ///      diagnostic to backend, pick the next-best country by ping and
    ///      pin it. Toast "Германия недоступна, переключено на NL".
    ///   3. **All direct countries dead (or `maxCascadeDepth` hit)** —
    ///      jump to SPB whitelist-bypass relays as last resort. Toast.
    ///   4. **SPB relays also dead** — toast "Сеть недоступна", log error,
    ///      fire diagnostic. Stop probing for the rest of the cooldown
    ///      window.
    ///
    /// Manual user pick clears the cascade state and resets the chain.
    func performFallbackForCurrentLeg() async {
        guard vpnManager.isConnected else { return }
        let pinned = configStore.selectedServerTag
        let shape = ServerTagShape(pinned)
        guard let group = servers.first(where: { $0.type == "selector" && $0.selectable }) else {
            TunnelFileLogger.log("fallback: no selector group, skipping", category: "ui")
            return
        }

        switch shape {
        case .leaf:
            await fallbackFromLeaf(pinned: pinned!, group: group)
        case .countryUrltest:
            await fallbackFromCountry(pinned: pinned!, group: group)
        case .auto, .unknown:
            await fallbackOnAuto(group: group)
        }
    }

    private func fallbackFromLeaf(pinned: String, group: ServerGroup) async {
        deadLeavesInCurrentCascade.insert(pinned)
        TunnelFileLogger.log("fallback: leaf '\(pinned)' marked dead (cascade leaves=\(deadLeavesInCurrentCascade.count))", category: "ui")

        guard let country = group.countries.first(where: { $0.serverTags.contains(pinned) }) else {
            TunnelFileLogger.log("fallback: leaf '\(pinned)' has no country, escalating", category: "ui")
            await escalateBeyondCountry(group: group, exhaustedCountry: nil, reason: "leaf orphan")
            return
        }

        let candidates = country.serverTags.filter { !deadLeavesInCurrentCascade.contains($0) }
        if let next = candidates.first {
            TunnelFileLogger.log("fallback: leaf '\(pinned)' → leaf '\(next)' (same country '\(country.tag)')", category: "ui")
            selectServer(groupTag: group.tag, serverTag: next, clearCascade: false)
            fallbackToastMessage = L10n.Recovery.switchedLeg(country.name)
            return
        }

        TunnelFileLogger.log("fallback: all leaves in '\(country.tag)' tried, escalating", category: "ui")
        deadCountriesInCurrentCascade.insert(country.tag)
        reportDiagnostic(event: "country_dead", country: country.tag, deadLeaves: Array(deadLeavesInCurrentCascade))
        await escalateBeyondCountry(group: group, exhaustedCountry: country, reason: "country '\(country.name)' exhausted")
    }

    private func fallbackFromCountry(pinned: String, group: ServerGroup) async {
        // User pinned a country urltest. Build-35: try the next not-yet-tried
        // leaf inside the country *first* — sing-box's urltest can mis-pick
        // (HEAD passes on a path that drops real data), so cycling at our
        // layer reliably catches degraded paths even when sing-box's own
        // probe says everything is fine. Only escalate to the next country
        // when every leaf in this one has been tried this cascade.
        guard let country = group.countries.first(where: { $0.tag == pinned }) else {
            TunnelFileLogger.log("fallback: country tag '\(pinned)' not found, escalating", category: "ui")
            await escalateBeyondCountry(group: group, exhaustedCountry: nil, reason: "country tag '\(pinned)' missing")
            return
        }
        let activeLeaf = servers.first(where: { $0.tag == pinned })?.selected
        if let leaf = activeLeaf, !leaf.isEmpty {
            deadLeavesInCurrentCascade.insert(leaf)
            // Forget memory bias for this network+country — the remembered
            // leg is now dead under current conditions.
            if let fp = currentNetworkFingerprint, let cc = leafCountryCode(leaf) {
                lastWorkingLegStore.forget(fingerprint: fp, country: cc)
            }
        }
        let candidates = country.serverTags.filter { !deadLeavesInCurrentCascade.contains($0) }
        if let next = candidates.first {
            TunnelFileLogger.log("fallback: '\(pinned)' leaf '\(activeLeaf ?? "?")' → '\(next)' (same country)", category: "ui")
            // selectOutbound on Proxy with a leaf tag bypasses the country
            // urltest entirely — sing-box honours the explicit pick until
            // we set it back via another selectOutbound or the user picks
            // a country/Auto. The country pin in selectedServerTag is
            // preserved at the iOS state level so leaving and returning
            // re-pins.
            // selectOutbound itself closes existing connections so in-flight
            // sockets get re-dialled through the new leaf.
            commandClient.selectOutbound(groupTag: group.tag, outboundTag: next)
            fallbackToastMessage = L10n.Recovery.switchedLeg(country.name)
            return
        }
        // Every leaf in the country has been tried — promote to country-dead
        // and escalate.
        deadCountriesInCurrentCascade.insert(pinned)
        for leaf in country.serverTags { deadLeavesInCurrentCascade.insert(leaf) }
        TunnelFileLogger.log("fallback: all leaves in '\(pinned)' tried, escalating", category: "ui")
        reportDiagnostic(event: "country_dead", country: pinned, deadLeaves: country.serverTags)
        await escalateBeyondCountry(group: group, exhaustedCountry: country, reason: "country '\(pinned)' unreachable")
    }

    /// Extract two-letter country code from a leaf tag like "de-via-msk" → "DE".
    private func leafCountryCode(_ leaf: String) -> String? {
        let parts = leaf.split(separator: "-")
        guard let first = parts.first else { return nil }
        return first.uppercased()
    }

    private func fallbackOnAuto(group: ServerGroup) async {
        // Build-39: ask PathPicker for the next-best leaf across the whole
        // pool, excluding any we've already given up on this cascade. The
        // pre-build-39 path called `commandClient.urlTest(...)` per group
        // which was a no-op once urltest groups were removed from the
        // config; now we directly re-probe via NWConnection in main app
        // and push the new winner via Clash API.
        let candidates = leafCandidates()
        guard !candidates.isEmpty else {
            TunnelFileLogger.log("fallback(auto): no candidates, skipping", category: "ui")
            return
        }
        let demote = computeDemoteClasses()
        guard let leaf = await pathPicker.bestLeaf(
            excluding: deadLeavesInCurrentCascade,
            for: nil,                           // Auto = no country filter
            candidates: candidates,
            demoteClasses: demote
        ) else {
            TunnelFileLogger.log("fallback(auto): all candidates dead, giving up", category: "ui")
            return
        }
        TunnelFileLogger.log("fallback(auto): re-pick leaf='\(leaf)' demote=\(demote.map { "\($0)" }.sorted())", category: "ui")
        commandClient.selectOutbound(groupTag: group.tag, outboundTag: leaf)
        // No toast — recovery on Auto is the expected silent path.
    }

    /// Build-39: derive the cascade demote set from the per-network record
    /// in `LastWorkingLegStore`. If we have any successful records on this
    /// network and NONE of them are direct, demote `.direct` so the next
    /// fallback skips it entirely. Returns empty set when we have no
    /// records or when direct has worked here at least once.
    private func computeDemoteClasses() -> Set<LeafClass> {
        guard let fp = currentNetworkFingerprint else { return [] }
        guard let workedClasses = lastWorkingLegStore.classesEverWorked(fingerprint: fp) else {
            return [] // never connected on this network — no signal
        }
        var demote: Set<LeafClass> = []
        if !workedClasses.contains("direct") {
            demote.insert(.direct)
        }
        return demote
    }

    /// Pick the next-best country (or SPB relay), pin it, force its
    /// urltest to probe under current network. Called once per cascade
    /// step. Caller is responsible for marking the previous country dead.
    private func escalateBeyondCountry(
        group: ServerGroup,
        exhaustedCountry: CountryGroup?,
        reason: String
    ) async {
        // Cascade depth check — bound how many countries we'll try before
        // jumping straight to SPB. Without this a network with widespread
        // DPI could have us thrash through every country.
        let directCountries = group.countries.filter { $0.section == .direct && $0.id != "other" }
        let triedDirect = deadCountriesInCurrentCascade.intersection(Set(directCountries.map(\.tag))).count

        // Step A: try next direct country (sorted by best ping, dead-skipped)
        if triedDirect < maxCascadeDepth {
            let candidates = directCountries
                .filter { !deadCountriesInCurrentCascade.contains($0.tag) }
                .sorted { lhs, rhs in
                    // bestDelay 0 = unknown, push to end. Otherwise ascending.
                    let l = lhs.bestDelay > 0 ? Int(lhs.bestDelay) : Int.max
                    let r = rhs.bestDelay > 0 ? Int(rhs.bestDelay) : Int.max
                    return l < r
                }
            if let nextCountry = candidates.first {
                TunnelFileLogger.log("fallback: ESCALATE → country '\(nextCountry.tag)' (depth=\(triedDirect + 1)/\(maxCascadeDepth), reason: \(reason))", category: "ui")
                selectServer(groupTag: group.tag, serverTag: nextCountry.tag, clearCascade: false)
                if let from = exhaustedCountry {
                    fallbackToastMessage = L10n.Recovery.switchedFromTo(from.name, nextCountry.name)
                } else {
                    fallbackToastMessage = L10n.Recovery.switchedTo(nextCountry.name)
                }
                return
            }
        }

        // Step B: try SPB whitelist-bypass relays as last resort
        let bypassCountries = group.countries.filter { $0.section == .whitelistBypass }
        let allBypassLeaves = bypassCountries.flatMap(\.serverTags)
        let bypassLeavesAlive = allBypassLeaves.filter { !deadLeavesInCurrentCascade.contains($0) }
        if let firstBypassLeaf = bypassLeavesAlive.first {
            TunnelFileLogger.log("fallback: ESCALATE → SPB relay '\(firstBypassLeaf)' (last resort, reason: \(reason))", category: "ui")
            selectServer(groupTag: group.tag, serverTag: firstBypassLeaf, clearCascade: false)
            fallbackToastMessage = L10n.Recovery.switchedToBypass
            return
        }

        // Step C: nothing left
        TunnelFileLogger.log("fallback: ALL COUNTRIES + SPB DEAD — giving up (reason: \(reason))", category: "ui")
        reportDiagnostic(event: "all_dead", country: "*", deadLeaves: Array(deadLeavesInCurrentCascade))
        fallbackToastMessage = L10n.Recovery.allDead
        // Don't reset cascade — let the cooldown elapse, next stall will
        // start a fresh sequence (cascade sets are wiped on selectServer).
    }

    /// Fire-and-forget diagnostic POST to backend. Catches network errors
    /// silently — the cascade decision must not depend on whether ops
    /// telemetry succeeded. Backend appends to a log file ops can grep
    /// when a user reports "country X stopped working".
    private func reportDiagnostic(event: String, country: String, deadLeaves: [String]) {
        Task.detached { [weak self] in
            guard let self else { return }
            let token = await self.configStore.accessToken
            let networkType = await self.currentNetworkTypeLabel()
            try? await self.apiClient.reportDiagnostic(
                event: event,
                country: country,
                deadLeaves: deadLeaves,
                networkType: networkType,
                accessToken: token
            )
        }
    }

    /// Best-effort label for the active network type — used in diagnostic
    /// payloads only, never in routing decisions. Returns "wifi", "cellular",
    /// "wired", or "unknown".
    private func currentNetworkTypeLabel() -> String {
        // ROADMAP iOS-22: hook NWPathMonitor into AppState. For now the
        // extension's pathUpdate logs already capture this on the support
        // side, so the diagnostic payload is informational only.
        return "unknown"
    }
}
