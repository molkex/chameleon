import Foundation
import SwiftUI
import NetworkExtension

/// Central observable state container for the app.
@MainActor
@Observable
class AppState {
    let configStore = ConfigStore()
    let apiClient = APIClient()
    let vpnManager = VPNManager()
    let commandClient = CommandClientWrapper()
    let pingService = PingService()
    let subscriptionManager = SubscriptionManager()

    /// Server groups parsed from the saved config file.
    /// Available even when VPN is disconnected.
    var configServers: [ServerGroup] = []

    /// Tracks activation state. Backed by configStore but stored here
    /// so @Observable can detect changes and trigger SwiftUI updates.
    var isActivated: Bool = false
    var isLoading = false
    var errorMessage: String?

    private var statusObserver: Any?

    private var vpnConnectStart: Date?

    /// Timestamp when the VPN entered .connected state. Persists across tab switches.
    var vpnConnectedAt: Date? = nil

    /// Guards against re-applying the saved server preference after the user
    /// manually changes server mid-session. Reset on every disconnect.
    private var serverPreferenceApplied = false

    func initialize() async {
        // Check StoreKit subscription status (runs concurrently with rest of init)
        async let storeKitCheck: Void = subscriptionManager.checkSubscriptionStatus()

        // Sync activation state from persisted store OR active StoreKit subscription
        _ = await storeKitCheck
        isActivated = configStore.isActivated || subscriptionManager.isPremium

        // Parse servers from saved config (available before VPN connects)
        reloadConfigServers()

        // When gRPC delivers groups after VPN connects, apply saved server preference
        // and immediately trigger URL tests so ping data appears without waiting 5 min
        commandClient.onGroupsReceived = { [weak self] groups in
            guard let self else { return }
            // Apply saved preference only once per connection session to avoid
            // overriding a server the user picks manually after connecting.
            if !self.serverPreferenceApplied {
                self.applyPreferredServerIfNeeded()
                self.serverPreferenceApplied = true
            }
            // Trigger URL test on main urltest group to populate pings right away
            if let autoGroup = groups.first(where: { $0.type == "urltest" }) {
                self.commandClient.urlTest(groupTag: autoGroup.tag)
            }
        }

        do {
            try await vpnManager.load()
            startObservingVPNStatus()

            if vpnManager.isConnected {
                commandClient.connect()
            }
        } catch {
            AppLogger.app.error("VPN manager load failed: \(error)")
        }

        // Auto-update config on every app launch — if config changed, reconnect
        if isActivated {
            Task {
                let oldConfig = configStore.loadConfig()
                await silentConfigUpdate()
                let newConfig = configStore.loadConfig()
                if vpnManager.isConnected, let new = newConfig, new != oldConfig {
                    AppLogger.app.info("Config changed on launch — reconnecting VPN")
                    await reconnectIfActive()
                }
            }
        }

        // Telemetry: fetch real IP + ping all servers on launch and report
        if isActivated {
            TelemetryService.shared.fetchRealIP()
            TelemetryService.shared.trackEvent("app_launch")
            pingService.pingAll(groups: configServers)
            // Wait for ping to complete, then send
            Task {
                while pingService.isPinging { try? await Task.sleep(for: .milliseconds(500)) }
                TelemetryService.shared.collectAndSend(
                    username: configStore.username,
                    pingResults: pingService.results,
                    vpnConnected: vpnManager.isConnected,
                    selectedServer: selectedServerTag
                )
            }
        }
    }

    /// Apply the saved server preference via gRPC when groups become available.
    private func applyPreferredServerIfNeeded() {
        guard let preferredTag = configStore.selectedServerTag else { return }

        let groups = commandClient.groups
        let selectorGroup = groups.first { g in
            g.type == "selector" && g.items.contains(where: { $0.type == "urltest" })
        }
        let urltestGroups = groups.filter { $0.type == "urltest" }
        let autoGroupTag = urltestGroups.max(by: { $0.items.count < $1.items.count })?.tag ?? ""

        // Case A: preferredTag is a country urltest group (e.g. "⚡ NL") → point selector to it
        if let sel = selectorGroup, sel.items.contains(where: { $0.tag == preferredTag }) {
            guard sel.selected != preferredTag else { return }
            AppLogger.app.info("Applying saved server preference (country): \(preferredTag)")
            commandClient.selectOutbound(groupTag: sel.tag, outboundTag: preferredTag)
            return
        }

        // Case B: preferredTag is an individual server (e.g. "relay-nl")
        // Find the country urltest group that owns this server, pin it there,
        // then point the selector to that country group.
        if let countryGroup = groups.first(where: { g in
            g.type == "urltest" &&
            g.tag != autoGroupTag &&
            g.items.contains(where: { $0.tag == preferredTag })
        }) {
            AppLogger.app.info("Applying saved server preference (individual): \(preferredTag) via \(countryGroup.tag)")
            commandClient.selectOutbound(groupTag: countryGroup.tag, outboundTag: preferredTag)
            if let sel = selectorGroup {
                commandClient.selectOutbound(groupTag: sel.tag, outboundTag: countryGroup.tag)
            }
            return
        }

        // Fallback: pin auto urltest group directly (old config without selector)
        guard let autoGroup = groups.first(where: { $0.type == "urltest" }) else { return }
        guard autoGroup.items.contains(where: { $0.tag == preferredTag }) else { return }
        guard autoGroup.selected != preferredTag else { return }
        AppLogger.app.info("Applying saved server preference (auto urltest): \(preferredTag)")
        commandClient.selectOutbound(groupTag: autoGroup.tag, outboundTag: preferredTag)
    }

    /// Reload server list from the saved config file.
    func reloadConfigServers() {
        configServers = configStore.parseServersFromConfig()
    }

    /// The preferred server tag saved by the user. Nil = auto.
    var selectedServerTag: String? {
        configStore.selectedServerTag
    }

    /// Save preferred server selection. Pass nil to reset to auto.
    /// Tag is a country urltest group tag (e.g. "⚡ NL", "⚡ DE") or nil for auto.
    func selectPreferredServer(tag: String?) {
        TelemetryService.shared.trackEvent("server_select", params: ["tag": tag ?? "auto"])
        configStore.selectedServerTag = tag
        // Update configServers — update server selector group selection for UI
        for i in configServers.indices {
            if configServers[i].type == "selector" &&
               configServers[i].items.contains(where: { $0.type == "urltest" }) {
                // Server selector group — update selection
                let newSelected = tag ?? configServers[i].items.first?.tag ?? ""
                configServers[i].selected = newSelected
            }
        }
    }

    // MARK: - VPN Status Observation

    private func startObservingVPNStatus() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleVPNStatusChange()
            }
        }
    }

    private func handleVPNStatusChange() {
        switch vpnManager.status {
        case .connecting:
            vpnConnectStart = Date()
        case .connected:
            if vpnConnectedAt == nil {
                vpnConnectedAt = Date()
            }
            if !commandClient.isConnected {
                commandClient.connect()
            }
            // Telemetry: report successful connection with protocol info
            let duration = vpnConnectStart.map { Date().timeIntervalSince($0) }
            let proto = commandClient.selectedServer?.protocolLabel
            TelemetryService.shared.trackEvent("vpn_connected", params: [
                "duration_ms": Int((duration ?? 0) * 1000),
                "server": selectedServerTag ?? "auto"
            ])
            TelemetryService.shared.collectAndSend(
                username: configStore.username,
                vpnConnected: true,
                selectedServer: selectedServerTag,
                connectDuration: duration,
                selectedProtocol: proto
            )
        case .disconnected, .invalid:
            vpnConnectedAt = nil
            serverPreferenceApplied = false
            if commandClient.isConnected || commandClient.statsAvailable {
                commandClient.disconnect()
            }
        default:
            break
        }
    }

    // MARK: - Activation

    /// Register device for trial (standalone, no Telegram).
    func registerDevice() async throws {
        isLoading = true
        defer { isLoading = false }

        let (username, expire) = try await apiClient.registerDevice()
        configStore.username = username
        if expire > 0 {
            configStore.subscriptionExpire = Date(timeIntervalSince1970: TimeInterval(expire))
        }
        try await updateConfig()
        isActivated = true
    }

    /// Activate with code from Telegram bot.
    func activate(code: String) async throws {
        isLoading = true
        defer { isLoading = false }

        let username = try await apiClient.activateCode(code)
        configStore.username = username
        try await updateConfig()
        isActivated = true
    }

    func updateConfig(mode: String? = nil) async throws {
        guard let username = configStore.username else { return }
        let effectiveMode = mode ?? configStore.vpnMode
        let result = try await apiClient.fetchConfig(
            username: username,
            accessToken: configStore.accessToken,
            mode: effectiveMode
        )
        try configStore.saveConfig(result.config)
        if result.expire > 0 {
            configStore.subscriptionExpire = Date(timeIntervalSince1970: TimeInterval(result.expire))
        }
        reloadConfigServers()
    }

    /// Set the VPN mode (e.g. "smart" or "fullvpn"), download fresh config and reconnect if active.
    func setVPNMode(_ mode: String) async {
        configStore.vpnMode = mode
        do {
            try await updateConfig(mode: mode)
            if vpnManager.isConnected {
                await reconnectIfActive()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Disconnect VPN, wait for full disconnect, then reconnect with current config.
    func reconnectIfActive() async {
        guard vpnManager.isConnected else { return }
        // Disable On Demand FIRST — otherwise iOS auto-reconnects with old config
        // before we get a chance to start the tunnel with the new config
        await vpnManager.disableOnDemand()
        disconnectVPN()
        // Wait up to 3s for tunnel to fully stop before starting again
        for _ in 0..<15 {
            if vpnManager.status == NEVPNStatus.disconnected { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        await connectVPN()
        // If after the attempt we're still not connected — show an error
        try? await Task.sleep(for: .seconds(3))
        if !vpnManager.isConnected {
            await MainActor.run {
                if errorMessage == nil || errorMessage!.isEmpty {
                    errorMessage = "Не удалось переподключиться. Попробуй ещё раз."
                }
            }
        }
    }

    /// Silently fetch and save latest config. On 401, tries token refresh then retries.
    private func silentConfigUpdate() async {
        guard let username = configStore.username else { return }
        let mode = configStore.vpnMode
        do {
            let fresh = try await apiClient.fetchConfig(
                username: username,
                accessToken: configStore.accessToken,
                mode: mode
            )
            try configStore.saveConfig(fresh.config)
            if fresh.expire > 0 {
                configStore.subscriptionExpire = Date(timeIntervalSince1970: TimeInterval(fresh.expire))
            }
            reloadConfigServers()
            AppLogger.app.info("Config auto-updated")
        } catch APIError.unauthorized {
            // Access token expired — try refresh
            guard let refreshToken = configStore.refreshToken else { return }
            do {
                let newAccess = try await apiClient.refreshAccessToken(refreshToken)
                configStore.accessToken = newAccess
                let fresh = try await apiClient.fetchConfig(
                    username: username,
                    accessToken: newAccess,
                    mode: mode
                )
                try configStore.saveConfig(fresh.config)
                if fresh.expire > 0 {
                    configStore.subscriptionExpire = Date(timeIntervalSince1970: TimeInterval(fresh.expire))
                }
                reloadConfigServers()
                AppLogger.app.info("Config auto-updated after token refresh")
            } catch {
                AppLogger.app.debug("Config update failed after refresh: \(error.localizedDescription)")
            }
        } catch {
            AppLogger.app.error("Config update failed: \(error.localizedDescription)")
            await MainActor.run {
                self.errorMessage = "Конфиг: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - JWT Auth (Apple / Phone)

    func authenticateWithApple(identityToken: String, userIdentifier: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await apiClient.signInWithApple(
                identityToken: identityToken,
                userIdentifier: userIdentifier
            )
            configStore.accessToken = result.accessToken
            configStore.refreshToken = result.refreshToken
            configStore.username = result.username
            if let exp = result.expire, exp > 0 {
                configStore.subscriptionExpire = Date(timeIntervalSince1970: TimeInterval(exp))
            }
            try await updateConfig()
            isActivated = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func authenticateWithAppleAndCode(identityToken: String, userIdentifier: String, code: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await apiClient.signInWithAppleAndCode(
                identityToken: identityToken,
                userIdentifier: userIdentifier,
                code: code
            )
            configStore.accessToken = result.accessToken
            configStore.refreshToken = result.refreshToken
            configStore.username = result.username
            if let exp = result.expire, exp > 0 {
                configStore.subscriptionExpire = Date(timeIntervalSince1970: TimeInterval(exp))
            }
            try await updateConfig()
            isActivated = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - VPN Control

    func connectVPN() async {
        // If no config saved yet — must download before we can connect
        if !configStore.hasConfig() {
            isLoading = true
            defer { isLoading = false }
            await silentConfigUpdate()
            guard configStore.hasConfig() else {
                errorMessage = "Нет конфигурации. Проверьте подключение к интернету и попробуйте снова."
                return
            }
        } else {
            // Config exists — refresh it before connecting so user gets latest config
            await silentConfigUpdate()
        }

        let config = configStore.loadConfig()
        do {
            try await vpnManager.connect(configJSON: config)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnectVPN() {
        commandClient.disconnect()
        vpnManager.disconnect()
    }

    func toggleVPN() async {
        if vpnManager.isConnected {
            disconnectVPN()
        } else {
            await connectVPN()
        }
    }

    func logout() {
        disconnectVPN()
        configStore.clear()
        isActivated = false
    }

    /// Remove the stale VPN profile and recreate it on next connect.
    /// Fixes "VPN shows Connected but doesn't route traffic" iOS bug.
    func resetVPNProfile() async throws {
        try await vpnManager.resetProfile()
        // Clear persisted tunnel config from shared UserDefaults so
        // On Demand reconnects don't use a stale/broken config.
        UserDefaults(suiteName: AppConstants.appGroupID)?
            .removeObject(forKey: AppConstants.startOptionsKey)
    }
}
