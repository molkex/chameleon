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

    /// Per-country failed-leaf attempts inside a single fallback cascade.
    /// Cleared whenever the user manually selects a server or the cascade
    /// settles back to a working state. Prevents the monitor from cycling
    /// through the same dead leaves forever — once a leaf has failed in
    /// the current sequence we skip it and escalate.
    @ObservationIgnored
    private var deadLeavesInCurrentCascade: Set<String> = []

    nonisolated(unsafe) private var statusObserver: Any?
    /// Background config refresh task (handleForeground, toggleVPN).
    nonisolated(unsafe) private var refreshTask: Task<Void, Never>?
    /// Server switch reconnect task (selectServer). Separate from refreshTask
    /// so that background config updates don't cancel reconnection.
    nonisolated(unsafe) private var reconnectTask: Task<Void, Never>?

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

        let hasSelector = outbounds.contains { ($0["type"] as? String) == "selector" }
        let hasUrltest = outbounds.contains { ($0["type"] as? String) == "urltest" }

        // Check for deprecated inbound fields (sing-box 1.13 deprecation)
        let inbounds = (json["inbounds"] as? [[String: Any]]) ?? []
        let hasLegacyInbound = inbounds.contains { $0["sniff"] != nil || $0["sniff_override_destination"] != nil }

        // Need both selector AND urltest, or it's a broken config. Parens
        // matter — without them && would bind tighter and treat configs with
        // only urltest as valid.
        if (!hasSelector || !hasUrltest) || hasLegacyInbound {
            // Config has deprecated fields — delete and re-fetch
            AppLogger.app.info("repairConfigIfNeeded: clearing outdated config")
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
        isLoading = true
        defer { isLoading = false }
        AppLogger.app.info("signInAnonymous: starting device registration")
        do {
            let result = try await apiClient.registerDevice()
            AppLogger.app.info("signInAnonymous: registered as \(result.username)")
            configStore.accessToken = result.accessToken
            configStore.refreshToken = result.refreshToken
            configStore.username = result.username
            try await fetchAndSaveConfig()
            subscriptionExpire = configStore.subscriptionExpire
            UserDefaults(suiteName: AppConstants.appGroupID)?.set(true, forKey: AppConstants.onboardingCompletedKey)
            isAuthenticated = true
        } catch {
            AppLogger.app.error("signInAnonymous: FAILED: \(error.localizedDescription)")
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
        return buildConfigWithSelections(chain: resolveSelectionChain(target: target))
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
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await apiClient.signInWithGoogle(idToken: idToken)
            AppLogger.app.info("signInWithGoogle: username=\(result.username), isNew=\(result.isNew ?? false)")
            configStore.accessToken = result.accessToken
            configStore.refreshToken = result.refreshToken
            configStore.username = result.username
            try await fetchAndSaveConfig()
            subscriptionExpire = configStore.subscriptionExpire
            UserDefaults(suiteName: AppConstants.appGroupID)?.set(true, forKey: AppConstants.onboardingCompletedKey)
            isAuthenticated = true
        } catch {
            AppLogger.app.error("signInWithGoogle: failed: \(String(describing: error), privacy: .public)")
            errorMessage = String(localized: "onboarding.signin_failed")
        }
    }

    /// Email entry: ask backend to send a magic link. Always resolves to a
    /// "check your email" confirmation in UI, even on rate-limit, because we
    /// don't want to leak which addresses have accounts.
    func requestMagicLink(email: String) async -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = String(localized: "magic.error.invalid_email")
            return false
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await apiClient.requestMagicLink(email: trimmed)
            return true
        } catch let APIError.serverError(429) {
            errorMessage = String(localized: "magic.error.rate_limited")
            return false
        } catch {
            AppLogger.app.error("requestMagicLink: failed: \(String(describing: error), privacy: .public)")
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
        if wasAuthenticated {
            errorMessage = String(localized: "magic.already_signed_in")
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await apiClient.verifyMagicLink(token: token)
            AppLogger.app.info("consumeMagicToken: username=\(result.username), isNew=\(result.isNew ?? false)")
            configStore.accessToken = result.accessToken
            configStore.refreshToken = result.refreshToken
            configStore.username = result.username
            try await fetchAndSaveConfig()
            subscriptionExpire = configStore.subscriptionExpire
            UserDefaults(suiteName: AppConstants.appGroupID)?.set(true, forKey: AppConstants.onboardingCompletedKey)
            isAuthenticated = true
        } catch {
            AppLogger.app.error("consumeMagicToken: failed: \(String(describing: error), privacy: .public)")
            errorMessage = String(localized: "magic.error.invalid_link")
        }
    }

    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async {
        AppLogger.app.info("signInWithApple: entry, hasToken=\(credential.identityToken != nil, privacy: .public), user=\(credential.user, privacy: .public)")
        guard let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            AppLogger.app.error("signInWithApple: no identity token in credential")
            errorMessage = String(localized: "onboarding.signin_failed")
            return
        }
        AppLogger.app.info("signInWithApple: got token, len=\(token.count, privacy: .public)")

        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await apiClient.signInWithApple(identityToken: token)
            AppLogger.app.info("signInWithApple: username=\(result.username), isNew=\(result.isNew ?? false)")
            configStore.accessToken = result.accessToken
            configStore.refreshToken = result.refreshToken
            configStore.username = result.username
            try await fetchAndSaveConfig()
            subscriptionExpire = configStore.subscriptionExpire
            UserDefaults(suiteName: AppConstants.appGroupID)?.set(true, forKey: AppConstants.onboardingCompletedKey)
            isAuthenticated = true
        } catch {
            AppLogger.app.error("signInWithApple: failed: \(String(describing: error), privacy: .public)")
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

    func toggleVPN() async {
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
            TunnelFileLogger.log("toggleVPN: have cached config, building...", category: "ui")
            let config: String? = configForStartup() ?? configStore.loadConfig()
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

            // Watchdog: the tunnel must reach .connected within 10s. The
            // preflight probe already confirmed at least one outbound is
            // network-reachable, so the remaining failure modes (Reality
            // handshake mismatch, bad UUID) surface in <10s — no reason
            // to make the user wait 30.
            let outcome = await vpnManager.waitUntilConnected(timeout: .seconds(10))
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
                TunnelFileLogger.log("toggleVPN: watchdog — timed out after 10s", category: "ui")
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

        let outcome = await vpnManager.waitUntilConnected(timeout: .seconds(10))
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
        // so the dead-leaf set survives the hop.
        if clearCascade {
            deadLeavesInCurrentCascade.removeAll()
        }
        trafficHealthMonitor?.suspendForManualSwitch()

        // Persist the full multi-step selection into the cached startOptions
        // immediately, regardless of whether the tunnel is currently up. This
        // ensures a cold-start connect reads the right selector defaults
        // rather than falling back to "Auto"/"direct" and routing through
        // the wrong country.
        let persistTarget = isAuto ? "Auto" : serverTag
        if let persisted = buildConfigWithSelections(chain: resolveSelectionChain(target: persistTarget)) {
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
        let chain = resolveSelectionChain(target: selectorTarget)
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

        // Fast path: live tunnel — apply every step in order via Clash API.
        if commandClient.isConnected {
            for step in chain {
                TunnelFileLogger.log("selectServer: LIVE selectOutbound '\(step.group)' → '\(step.target)'", category: "ui")
                commandClient.selectOutbound(groupTag: step.group, outboundTag: step.target)
            }
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
    private func applyServerSelectionIfLive() {
        let serverTag = configStore.selectedServerTag
        let selectorTarget = serverTag ?? "Auto"
        let chain = resolveSelectionChain(target: selectorTarget)
        guard !chain.isEmpty else {
            AppLogger.app.error("applyServerSelectionIfLive: chain empty for '\(selectorTarget)'")
            return
        }

        // Retry with backoff — same pattern as applyRoutingModeIfLive.
        // commandClient binds to the extension's unix socket after the tunnel
        // is up, and that race used to drop the server-selection pin here
        // (routing mode's retry ran on its own Task; this function returned
        // early and the Proxy selector kept its fresh-config default "Auto",
        // so Auto urltest picked the lowest-RTT leaf regardless of the
        // user's country pick). Retry every 500ms for 5s.
        guard commandClient.isConnected else {
            TunnelFileLogger.log("applyServerSelectionIfLive: cmdClient not connected, scheduling retry for '\(selectorTarget)'", category: "ui")
            Task { [weak self] in
                for attempt in 1...10 {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    if self.commandClient.isConnected {
                        TunnelFileLogger.log("applyServerSelectionIfLive: cmdClient ready after \(attempt * 500)ms, applying '\(selectorTarget)'", category: "ui")
                        for step in chain {
                            TunnelFileLogger.log("applyServerSelectionIfLive: '\(step.group)' → '\(step.target)'", category: "ui")
                            self.commandClient.selectOutbound(groupTag: step.group, outboundTag: step.target)
                        }
                        return
                    }
                }
                TunnelFileLogger.log("applyServerSelectionIfLive: cmdClient still not connected after 5s, giving up", category: "ui")
            }
            return
        }
        for step in chain {
            TunnelFileLogger.log("applyServerSelectionIfLive: '\(step.group)' → '\(step.target)'", category: "ui")
            commandClient.selectOutbound(groupTag: step.group, outboundTag: step.target)
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
            Task { [weak self] in
                for attempt in 1...10 {
                    try? await Task.sleep(for: .milliseconds(500))
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
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
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

    /// Hook called by MadFrogVPNApp on `scenePhase` change. Resumes the
    /// monitor when the app becomes active and pauses it on background —
    /// URLSession in the suspended main app would just stall forever.
    func handleScenePhaseActive(_ active: Bool) {
        let wasActive = isAppActive
        isAppActive = active
        TunnelFileLogger.log("scene phase: active=\(active)", category: "ui")
        if active && !wasActive {
            // Coming back to foreground: re-evaluate eligibility. The
            // monitor itself short-circuits if not eligible.
            startTrafficHealthMonitorIfEligible()
        }
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
                log: { msg in
                    TunnelFileLogger.log(msg, category: "ui")
                }
            ))
        }
        guard configStore.autoRecoverEnabled, vpnManager.isConnected, isAppActive else { return }
        trafficHealthMonitor?.start()
    }

    /// Smart fallback chain executed when the monitor decides the current
    /// leg is dead. Strategy mirrors what mature VPN clients do (Mullvad,
    /// ProtonVPN, Cloudflare WARP):
    ///
    ///   1. Pinned leaf: blacklist it for the current cascade, try the
    ///      next leaf inside the same country. Stay in country — silent,
    ///      no toast.
    ///   2. All leaves in pinned country are dead: escalate to Auto and
    ///      surface a localized toast so the user knows the country pin
    ///      is no longer in effect.
    ///   3. Pinned country urltest (or current state already): trigger
    ///      `urlTest("Auto")` + `closeConnections()` to force sing-box
    ///      to re-elect. No tag change.
    ///
    /// All log lines are written to TunnelFileLogger so support reports
    /// can attribute fallback events. Manual user actions take immediate
    /// priority — `selectServer` clears `deadLeavesInCurrentCascade`.
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
        TunnelFileLogger.log("fallback: leaf '\(pinned)' marked dead (cascade size=\(deadLeavesInCurrentCascade.count))", category: "ui")

        // Find the country this leaf belongs to and pick the next
        // not-yet-tried leaf in the same country.
        guard let country = group.countries.first(where: { $0.serverTags.contains(pinned) }) else {
            TunnelFileLogger.log("fallback: leaf '\(pinned)' has no country, escalating to Auto", category: "ui")
            await escalateToAuto(reason: "leaf orphan", group: group)
            return
        }

        let candidates = country.serverTags.filter { !deadLeavesInCurrentCascade.contains($0) }
        if let next = candidates.first {
            TunnelFileLogger.log("fallback: leaf '\(pinned)' → leaf '\(next)' (same country '\(country.tag)')", category: "ui")
            selectServer(groupTag: group.tag, serverTag: next, clearCascade: false)
            fallbackToastMessage = L10n.Recovery.switchedLeg(country.name)
            return
        }

        // All leaves in this country exhausted — escalate.
        TunnelFileLogger.log("fallback: all leaves in '\(country.tag)' tried, escalating to Auto", category: "ui")
        await escalateToAuto(reason: "country '\(country.name)' exhausted", group: group, country: country)
    }

    private func fallbackFromCountry(pinned: String, group: ServerGroup) async {
        // User pinned a country urltest. sing-box's urltest cycles the
        // leaves itself; if we still got here, the country itself is
        // dark — escalate to Auto.
        let country = group.countries.first(where: { $0.tag == pinned })
        TunnelFileLogger.log("fallback: country '\(pinned)' unreachable, escalating to Auto", category: "ui")
        await escalateToAuto(reason: "country '\(pinned)' unreachable", group: group, country: country)
    }

    private func fallbackOnAuto(group: ServerGroup) async {
        // Already on Auto — just kick the urltest + close existing
        // connections so the next request renegotiates over a fresh leg.
        TunnelFileLogger.log("fallback: on Auto already, re-running urltest + closeConnections", category: "ui")
        commandClient.urlTest(groupTag: "Auto")
        commandClient.urlTest(groupTag: group.tag)
        // No toast — silent recovery on Auto is the expected path.
    }

    private func escalateToAuto(reason: String, group: ServerGroup, country: CountryGroup? = nil) async {
        TunnelFileLogger.log("fallback: ESCALATE → Auto (reason: \(reason))", category: "ui")
        // Wipe cascade BEFORE selectServer (which keeps it as-is when
        // clearCascade=false would have been passed). Auto is a fresh start.
        deadLeavesInCurrentCascade.removeAll()
        selectServer(groupTag: group.tag, serverTag: "Auto")
        if let country {
            fallbackToastMessage = L10n.Recovery.switchedToAuto(country.name)
        } else {
            fallbackToastMessage = L10n.Recovery.switchedToAuto("")
        }
    }
}
