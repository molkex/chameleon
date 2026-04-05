import Foundation
import SwiftUI
import NetworkExtension

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

    private var statusObserver: Any?

    func initialize() async {
        // Fix: if config file is corrupted (missing selector/urltest), delete it
        // so fresh config is fetched from API
        repairConfigIfNeeded()

        servers = configStore.parseServersFromConfig()

        do {
            try await vpnManager.load()
            startObservingVPNStatus()
            if vpnManager.isConnected {
                commandClient.connect()
            }
        } catch {
            AppLogger.app.error("VPN load failed: \(error)")
        }

        // Auto-register if no username yet
        if configStore.username == nil {
            await autoRegister()
        }

        // Refresh config silently
        if configStore.username != nil {
            await silentConfigUpdate()
        }
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
        let hasDnsOutbound = outbounds.contains { ($0["type"] as? String) == "dns" }

        if !hasSelector && !hasUrltest || hasDnsOutbound {
            // Config is stripped or has deprecated dns outbound — delete and re-fetch
            AppLogger.app.info("repairConfigIfNeeded: clearing outdated config (hasDns=\(hasDnsOutbound), hasSelector=\(hasSelector))")
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
        let result = try await apiClient.fetchConfig(username: username, accessToken: configStore.accessToken)
        AppLogger.app.info("fetchAndSaveConfig: got config, length=\(result.config.count)")
        try configStore.saveConfig(result.config)
        servers = configStore.parseServersFromConfig()
        AppLogger.app.info("fetchAndSaveConfig: parsed \(self.servers.count) groups, total items=\(self.servers.flatMap(\.items).count)")
    }

    private func silentConfigUpdate() async {
        do {
            try await fetchAndSaveConfig()
        } catch {
            AppLogger.app.error("Config update failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - VPN

    func toggleVPN() async {
        if vpnManager.isConnected {
            commandClient.disconnect()
            vpnManager.disconnect()
        } else {
            // If we already have a cached config, connect immediately
            // and update config in background for next time
            if configStore.hasConfig() {
                let config = configStore.loadConfig()
                do {
                    try await vpnManager.connect(configJSON: config)
                } catch {
                    errorMessage = error.localizedDescription
                }
                // Update config in background for next connection
                Task { await silentConfigUpdate() }
            } else {
                // No cached config — must fetch first
                isLoading = true
                await silentConfigUpdate()
                isLoading = false
                guard configStore.hasConfig() else {
                    errorMessage = "No config available"
                    return
                }
                let config = configStore.loadConfig()
                do {
                    try await vpnManager.connect(configJSON: config)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func selectServer(groupTag: String, serverTag: String) {
        let previousTag = configStore.selectedServerTag
        configStore.selectedServerTag = serverTag

        // Update local servers array so UI reflects the change immediately
        for i in servers.indices {
            if servers[i].items.contains(where: { $0.tag == serverTag }) {
                servers[i] = ServerGroup(
                    id: servers[i].id, tag: servers[i].tag, type: servers[i].type,
                    selected: serverTag, items: servers[i].items, selectable: servers[i].selectable
                )
            }
        }

        guard vpnManager.isConnected, previousTag != serverTag else { return }

        // Build config with selector default changed (in memory only — don't overwrite file)
        guard let updatedConfig = buildConfigWithSelector(serverTag) else { return }

        // Write to UserDefaults for On-Demand reconnects (file stays as original full config)
        UserDefaults(suiteName: AppConstants.appGroupID)?.set(updatedConfig, forKey: AppConstants.startOptionsKey)

        Task {
            commandClient.disconnect()
            await vpnManager.disableOnDemand()
            vpnManager.disconnect()
            try? await Task.sleep(for: .seconds(1))
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
        else { return nil }

        for i in outbounds.indices {
            if outbounds[i]["type"] as? String == "selector" {
                outbounds[i]["default"] = serverTag
            }
        }
        json["outbounds"] = outbounds

        guard let updatedData = try? JSONSerialization.data(withJSONObject: json),
              let updatedConfig = String(data: updatedData, encoding: .utf8)
        else { return nil }

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
