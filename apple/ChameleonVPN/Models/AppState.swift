import Foundation
import SwiftUI
import NetworkExtension
import AuthenticationServices

@MainActor
@Observable
class AppState {
    let configStore = ConfigStore()
    let apiClient = APIClient()
    let vpnManager = VPNManager()
    let commandClient = CommandClientWrapper()

    var servers: [ServerGroup] = []
    var isLoading = false
    var errorMessage: String?
    var vpnConnectedAt: Date?
    var subscriptionExpire: Date?
    var isAuthenticated: Bool = false

    private var statusObserver: Any?

    private var hasInitialized = false

    func initialize() async {
        // Fix: if config file is corrupted (missing selector/urltest), delete it
        // so fresh config is fetched from API
        repairConfigIfNeeded()

        // Fix: if cached config is an error response (not a valid sing-box config),
        // clear everything and force re-registration.
        // App Group UserDefaults and Keychain survive app reinstall on iOS.
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
            if vpnManager.isConnected {
                commandClient.connect()
            }
        } catch {
            AppLogger.app.error("VPN load failed: \(error)")
        }

        // Refresh config silently on app launch (only if already signed in)
        if configStore.username != nil {
            await silentConfigUpdate()
        }

        hasInitialized = true
    }

    /// Called when app returns to foreground. Refreshes config in background.
    func handleForeground() async {
        guard hasInitialized, configStore.username != nil else { return }
        AppLogger.app.info("handleForeground: refreshing config in background")
        Task { await silentConfigUpdate() }
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

    private func autoRegister() async {
        isLoading = true
        defer { isLoading = false }
        AppLogger.app.info("autoRegister: starting device registration")
        do {
            let result = try await apiClient.registerDevice()
            AppLogger.app.info("autoRegister: registered as \(result.username)")
            configStore.accessToken = result.accessToken
            configStore.refreshToken = result.refreshToken
            configStore.username = result.username
            try await fetchAndSaveConfig()
        } catch {
            AppLogger.app.error("autoRegister: FAILED: \(error.localizedDescription)")
            errorMessage = "Registration failed: \(error.localizedDescription)"
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
                    configForUD = buildConfigWithSelector(tag) ?? config
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

    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async {
        guard let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            errorMessage = "Sign in failed: no identity token"
            return
        }

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
            isAuthenticated = true
        } catch {
            AppLogger.app.error("signInWithApple: failed: \(error.localizedDescription)")
            errorMessage = "Sign in failed. Please try again."
        }
    }

    // MARK: - VPN

    func toggleVPN() async {
        if vpnManager.isConnected {
            commandClient.disconnect()
            vpnManager.disconnect()
            // Refresh config in background for next connection
            Task { await silentConfigUpdate() }
        } else {
            // Fetch fresh config before connecting (up to 5s, then fall back to cache)
            await refreshConfig(timeout: .seconds(5))

            guard configStore.hasConfig() else {
                errorMessage = "No config available. Check internet connection."
                return
            }

            // Build config with selected server applied
            let config: String?
            if let tag = configStore.selectedServerTag {
                config = buildConfigWithSelector(tag) ?? configStore.loadConfig()
            } else {
                config = configStore.loadConfig()
            }

            do {
                try await vpnManager.connect(configJSON: config)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func selectServer(groupTag: String, serverTag: String) {
        let previousTag = configStore.selectedServerTag
        let isAuto = serverTag == "Auto"
        configStore.selectedServerTag = isAuto ? nil : serverTag
        AppLogger.app.info("selectServer: '\(previousTag ?? "Auto")' → '\(isAuto ? "Auto" : serverTag)', vpnConnected=\(self.vpnManager.isConnected)")

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
        guard vpnManager.isConnected, previousTag != effectiveNew else {
            AppLogger.app.info("selectServer: skipped reconnect (connected=\(self.vpnManager.isConnected), same=\(previousTag == effectiveNew))")
            return
        }

        // Build config with selector default changed (in memory only — don't overwrite file)
        let selectorTarget = isAuto ? "Auto" : serverTag
        guard let updatedConfig = buildConfigWithSelector(selectorTarget) else {
            AppLogger.app.error("selectServer: buildConfigWithSelector returned nil for '\(serverTag)'")
            return
        }

        AppLogger.app.info("selectServer: config built, selector default='\(selectorTarget)', reconnecting...")

        // Write to UserDefaults for On-Demand reconnects (file stays as original full config)
        UserDefaults(suiteName: AppConstants.appGroupID)?.set(updatedConfig, forKey: AppConstants.startOptionsKey)

        Task {
            commandClient.disconnect()
            await vpnManager.disableOnDemand()
            vpnManager.disconnect()
            // Wait for actual disconnect
            var waitCount = 0
            while vpnManager.isConnected && waitCount < 30 {
                try? await Task.sleep(for: .milliseconds(200))
                waitCount += 1
            }
            AppLogger.app.info("selectServer: disconnected after \(waitCount * 200)ms, reconnecting with new config")
            try? await vpnManager.connect(configJSON: updatedConfig)
        }
    }

    /// Build config with selector default set to the given server tag.
    /// Does NOT modify the config file — returns config string for in-memory use only.
    private func buildConfigWithSelector(_ serverTag: String) -> String? {
        guard let config = configStore.loadConfig(),
              let data = config.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var outbounds = json["outbounds"] as? [[String: Any]]
        else {
            AppLogger.app.error("buildConfigWithSelector: failed to load/parse config")
            return nil
        }

        var modified = false
        for i in outbounds.indices {
            if outbounds[i]["type"] as? String == "selector" {
                let selectorTag = outbounds[i]["tag"] as? String ?? "unknown"
                let members = outbounds[i]["outbounds"] as? [String] ?? []
                let oldDefault = outbounds[i]["default"] as? String ?? "nil"
                // Only modify selector that contains this serverTag
                if members.contains(serverTag) {
                    outbounds[i]["default"] = serverTag
                    modified = true
                    AppLogger.app.info("buildConfigWithSelector: selector '\(selectorTag)' default '\(oldDefault)' → '\(serverTag)' (members: \(members.joined(separator: ", ")))")
                } else {
                    AppLogger.app.warning("buildConfigWithSelector: selector '\(selectorTag)' does NOT contain '\(serverTag)', skipping (members: \(members.joined(separator: ", ")))")
                }
            }
        }

        if !modified {
            AppLogger.app.error("buildConfigWithSelector: no selector modified for '\(serverTag)'")
            return nil
        }

        json["outbounds"] = outbounds

        guard let updatedData = try? JSONSerialization.data(withJSONObject: json),
              let updatedConfig = String(data: updatedData, encoding: .utf8)
        else {
            AppLogger.app.error("buildConfigWithSelector: failed to serialize updated config")
            return nil
        }

        return updatedConfig
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
        switch vpnManager.status {
        case .connected:
            if vpnConnectedAt == nil { vpnConnectedAt = Date() }
            if !commandClient.isConnected { commandClient.connect() }
        case .disconnected, .invalid:
            vpnConnectedAt = nil
            if commandClient.isConnected { commandClient.disconnect() }
        default: break
        }
    }
}
