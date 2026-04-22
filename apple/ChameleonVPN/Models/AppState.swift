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
        subscriptionExpire = configStore.subscriptionExpire
        isAuthenticated = configStore.username != nil

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
        // dns outbound is now expected (used for DNS interception in 1.13)
        let hasDnsOutbound = false

        // Check for deprecated inbound fields
        let inbounds = (json["inbounds"] as? [[String: Any]]) ?? []
        let hasLegacyInbound = inbounds.contains { $0["sniff"] != nil || $0["sniff_override_destination"] != nil }

        if !hasSelector && !hasUrltest || hasDnsOutbound || hasLegacyInbound {
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
                let configForUD: String
                if let tag = configStore.selectedServerTag {
                    configForUD = buildConfigWithSelector(tag)?.config ?? config
                } else {
                    configForUD = config
                }
                UserDefaults(suiteName: AppConstants.appGroupID)?.set(configForUD, forKey: AppConstants.startOptionsKey)
            }
        } catch {
            AppLogger.app.error("Config update failed (using cached): \(error.localizedDescription)")
        }
    }

    /// Fetch fresh config with a timeout. Falls back to cached config if fetch fails or times out.
    private func refreshConfig(timeout: Duration = .seconds(5)) async {
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

    /// Called from ChameleonApp.handleUniversalLink when a /app/signin?token=…
    /// link is opened. Redeems the token and completes auth.
    func consumeMagicToken(_ token: String) async {
        AppLogger.app.info("consumeMagicToken: entry, tokenLen=\(token.count, privacy: .public)")
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
            let config: String?
            if let tag = configStore.selectedServerTag {
                config = buildConfigWithSelector(tag)?.config ?? configStore.loadConfig()
            } else {
                config = configStore.loadConfig()
            }
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

        let config: String?
        if let tag = configStore.selectedServerTag {
            config = buildConfigWithSelector(tag)?.config ?? configStore.loadConfig()
        } else {
            config = configStore.loadConfig()
        }

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

        let results: [(String, Int)] = await withTaskGroup(of: (String, Int).self) { group in
            for target in targets {
                group.addTask {
                    let ms = await PingService.probeTCP(host: target.host, port: target.port, timeout: 2.0)
                    return (target.tag, ms)
                }
            }
            var out: [(String, Int)] = []
            for await r in group { out.append(r) }
            return out
        }

        let anyAlive = results.contains { $0.1 > 0 }
        if anyAlive { return .ok }

        if selectedTag != nil, let dead = targets.first {
            return .selectedDead(name: dead.tag)
        }
        return .allDead
    }

    func selectServer(groupTag: String, serverTag: String) {
        let previousTag = configStore.selectedServerTag
        let isAuto = serverTag == "Auto"
        configStore.selectedServerTag = isAuto ? nil : serverTag
        TunnelFileLogger.log("selectServer: '\(previousTag ?? "Auto")' → '\(isAuto ? "Auto" : serverTag)', connected=\(vpnManager.isConnected), cmdClientConnected=\(commandClient.isConnected)", category: "ui")

        // Update local servers array so UI reflects the change immediately
        for i in servers.indices {
            if servers[i].items.contains(where: { $0.tag == serverTag }) {
                servers[i] = ServerGroup(
                    id: servers[i].id, tag: servers[i].tag, type: servers[i].type,
                    selected: serverTag, items: servers[i].items, selectable: servers[i].selectable
                )
            }
        }

        let effectiveNew = isAuto ? nil : serverTag
        let tagChanged = previousTag != effectiveNew
        guard vpnManager.isConnected else {
            AppLogger.app.info("selectServer: skipped (not connected), tag persisted")
            return
        }

        // Build config with selector default changed (for next cold start)
        let selectorTarget = isAuto ? "Auto" : serverTag
        let built = buildConfigWithSelector(selectorTarget)
        guard let updatedConfig = built?.config, let selectorTag = built?.selectorTag else {
            AppLogger.app.error("selectServer: buildConfigWithSelector returned nil for '\(serverTag)'")
            return
        }

        AppLogger.app.info("selectServer: selector='\(selectorTag)' target='\(selectorTarget)' tagChanged=\(tagChanged)")

        // Persist updated startOptions only when the tag actually changed.
        if tagChanged {
            UserDefaults(suiteName: AppConstants.appGroupID)?.set(updatedConfig, forKey: AppConstants.startOptionsKey)
        }

        // Fast path: if the command client is live, always fire selectOutbound
        // — even on a "same tag" tap. sing-box may have resolved Proxy to a
        // different outbound than configStore thinks (e.g., on cold start the
        // selector's default wasn't yet pinned to the persisted tag), so the
        // only reliable way to make the UI and the live tunnel agree is to
        // assert the selection every time the user taps.
        if commandClient.isConnected {
            TunnelFileLogger.log("selectServer: LIVE switch via selectOutbound selector='\(selectorTag)' → '\(selectorTarget)'", category: "ui")
            commandClient.selectOutbound(groupTag: selectorTag, outboundTag: selectorTarget)
            return
        }

        // Fallback: tunnel up but command client not yet connected. Only do a
        // full reconnect when the tag actually changed — no point tearing the
        // tunnel down to apply the same selection.
        guard tagChanged else { return }
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

    /// Re-applies the persisted server selection to the live tunnel. Called from
    /// handleStatus(.connected) so that a cold-start tunnel whose sing-box Proxy
    /// selector booted on a stale default gets forced onto the user's real pick.
    private func applyServerSelectionIfLive() {
        guard commandClient.isConnected else { return }
        let serverTag = configStore.selectedServerTag
        let selectorTarget = serverTag ?? "Auto"
        guard let built = buildConfigWithSelector(selectorTarget) else {
            AppLogger.app.error("applyServerSelectionIfLive: buildConfigWithSelector nil for '\(selectorTarget)'")
            return
        }
        TunnelFileLogger.log("applyServerSelectionIfLive: selector='\(built.selectorTag)' → '\(selectorTarget)'", category: "ui")
        commandClient.selectOutbound(groupTag: built.selectorTag, outboundTag: selectorTarget)
    }

    /// Build config with selector default set to the given server tag.
    /// Returns the updated config string and the selector tag that was modified.
    /// Does NOT modify the config file — caller persists via UserDefaults.
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
            if vpnConnectedAt == nil { vpnConnectedAt = Date() }
            if !commandClient.isConnected { commandClient.connect() }
            // Clear the user-stopped flag on successful connection
            sharedDefaults?.removeObject(forKey: "user_stopped_vpn")
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
        case .disconnected, .invalid:
            vpnConnectedAt = nil
            if commandClient.isConnected { commandClient.disconnect() }
            // Check if the PacketTunnel extension signaled a user-initiated stop
            // (from iOS Settings toggle). If so, disable On Demand to prevent auto-reconnect.
            let userStoppedVPN = sharedDefaults?.bool(forKey: "user_stopped_vpn") ?? false
            if userStoppedVPN {
                sharedDefaults?.removeObject(forKey: "user_stopped_vpn")
                AppLogger.app.info("handleStatus: user stopped VPN from Settings, disabling On Demand")
                Task { await vpnManager.disableOnDemand() }
            }
        default: break
        }
    }
}
