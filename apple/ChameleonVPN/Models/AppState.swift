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

    private func autoRegister() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await apiClient.registerDevice()
            configStore.accessToken = result.accessToken
            configStore.refreshToken = result.refreshToken
            configStore.username = result.username
            try await fetchAndSaveConfig()
        } catch {
            errorMessage = "Registration failed: \(error.localizedDescription)"
        }
    }

    private func fetchAndSaveConfig() async throws {
        guard let username = configStore.username else { return }
        let result = try await apiClient.fetchConfig(username: username, accessToken: configStore.accessToken)
        try configStore.saveConfig(result.config)
        servers = configStore.parseServersFromConfig()
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
            if !configStore.hasConfig() {
                isLoading = true
                await silentConfigUpdate()
                isLoading = false
                guard configStore.hasConfig() else {
                    errorMessage = "No config available"
                    return
                }
            }
            let config = configStore.loadConfig()
            do {
                try await vpnManager.connect(configJSON: config)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func selectServer(groupTag: String, serverTag: String) {
        configStore.selectedServerTag = serverTag
        if vpnManager.isConnected {
            commandClient.selectOutbound(groupTag: groupTag, outboundTag: serverTag)
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
