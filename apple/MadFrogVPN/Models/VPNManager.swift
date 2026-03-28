import Foundation
import NetworkExtension

/// Manages NETunnelProviderManager — connect/disconnect/status.
/// VPN permission is requested lazily on first connect, not on app launch.
@Observable
class VPNManager {
    private(set) var status: NEVPNStatus = .disconnected
    private var manager: NETunnelProviderManager?
    private var statusObserver: Any?

    var isConnected: Bool { status == .connected }
    var isProcessing: Bool { status == .connecting || status == .disconnecting || status == .reasserting }

    /// Load existing VPN config if any. Does NOT create or save — no permission prompt.
    func load() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        if let existing = managers.first {
            manager = existing
            observeStatus()
        }
        // If no existing manager, we'll create one on first connect
    }

    /// Connect VPN. Creates VPN config on first use (triggers iOS permission prompt).
    func connect(configJSON: String? = nil) async throws {
        // Ensure manager exists — create and save if first time
        if manager == nil {
            let m = createManager()
            try await m.saveToPreferences()  // ← iOS shows VPN permission HERE
            try await m.loadFromPreferences()
            manager = m
            observeStatus()
        }

        // Ensure profile is enabled
        if let m = manager, !m.isEnabled {
            m.isEnabled = true
            try await m.saveToPreferences()
            try await m.loadFromPreferences()
        }

        // Enable On Demand so iOS auto-reconnects on network changes
        if let m = manager, !m.isOnDemandEnabled {
            m.isOnDemandEnabled = true
            try? await m.saveToPreferences()
        }

        guard let session = manager?.connection as? NETunnelProviderSession else { return }

        var options: [String: NSObject]? = nil
        if let config = configJSON {
            options = ["configContent": config as NSString]
        }

        try session.startTunnel(options: options)
    }

    /// Disable On Demand so iOS doesn't auto-reconnect after disconnect.
    func disableOnDemand() async {
        guard let m = manager, m.isOnDemandEnabled else { return }
        m.isOnDemandEnabled = false
        try? await m.saveToPreferences()
    }

    func disconnect() {
        // Disable On Demand so iOS doesn't auto-reconnect after explicit disconnect
        if let m = manager, m.isOnDemandEnabled {
            m.isOnDemandEnabled = false
            m.saveToPreferences { _ in }
        }
        manager?.connection.stopVPNTunnel()
    }

    /// Remove VPN profile from iOS preferences and reset local state.
    /// The app can remove its own profile without authentication.
    /// On next connect(), a fresh profile will be created.
    func resetProfile() async throws {
        disconnect()
        if let m = manager {
            try await m.removeFromPreferences()
        }
        manager = nil
        if let obs = statusObserver {
            NotificationCenter.default.removeObserver(obs)
            statusObserver = nil
        }
        status = .disconnected
    }

    /// Send message to tunnel extension.
    func sendMessage(_ data: Data) async throws -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func observeStatus() {
        guard let manager, statusObserver == nil else { return }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main
        ) { [weak self] _ in
            self?.status = self?.manager?.connection.status ?? .disconnected
        }
        status = manager.connection.status
    }

    private func createManager() -> NETunnelProviderManager {
        let m = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppConstants.tunnelBundleID
        proto.serverAddress = "MadFrog VPN"
        proto.providerConfiguration = [:]
        m.protocolConfiguration = proto
        m.localizedDescription = "MadFrog VPN"
        m.isEnabled = true
        m.onDemandRules = [NEOnDemandRuleConnect()]
        m.isOnDemandEnabled = false
        return m
    }
}
