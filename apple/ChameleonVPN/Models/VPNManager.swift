import Foundation
import NetworkExtension
import os.log

/// Manages NETunnelProviderManager — connect/disconnect/status.
/// VPN permission is requested lazily on first connect, not on app launch.
///
/// MUST be @MainActor: SwiftUI's @Observable tracking requires mutations
/// to happen on MainActor for proper view invalidation. Without it,
/// status changes from NotificationCenter callbacks don't trigger re-renders.
@MainActor
@Observable
class VPNManager {
    private(set) var status: NEVPNStatus = .disconnected
    private var manager: NETunnelProviderManager?
    nonisolated(unsafe) private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VPN", category: "VPNManager")
    private var statusObserver: Any?
    /// Set to true when disconnect() is called from the app, reset on connect().
    /// Prevents disabling On Demand when iOS Settings or On Demand itself triggers disconnect.
    private(set) var userInitiatedDisconnect = false

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
        TunnelFileLogger.log("vpnManager.connect: begin", category: "ui")
        userInitiatedDisconnect = false

        // Ensure manager exists — create and save if first time
        if manager == nil {
            TunnelFileLogger.log("vpnManager.connect: manager==nil, creating", category: "ui")
            let m = createManager()
            try await m.saveToPreferences()  // ← iOS shows VPN permission HERE
            try await m.loadFromPreferences()
            manager = m
            observeStatus()
            TunnelFileLogger.log("vpnManager.connect: manager created", category: "ui")
        }

        // Ensure profile is enabled and On Demand is OFF.
        // On Demand with an unconditional Connect rule prevents the user from
        // disabling VPN via iOS Settings (iOS re-enables it immediately).
        if let m = manager {
            var needsSave = false
            if !m.isEnabled {
                m.isEnabled = true
                needsSave = true
            }
            if m.isOnDemandEnabled {
                m.isOnDemandEnabled = false
                needsSave = true
            }
            TunnelFileLogger.log("vpnManager.connect: enabled=\(m.isEnabled) onDemand=\(m.isOnDemandEnabled) needsSave=\(needsSave)", category: "ui")
            if needsSave {
                TunnelFileLogger.log("vpnManager.connect: awaiting saveToPreferences", category: "ui")
                try await m.saveToPreferences()
                TunnelFileLogger.log("vpnManager.connect: saveToPreferences OK, awaiting loadFromPreferences", category: "ui")
                try await m.loadFromPreferences()
                TunnelFileLogger.log("vpnManager.connect: loadFromPreferences OK", category: "ui")
            }
        }

        guard let session = manager?.connection as? NETunnelProviderSession else {
            TunnelFileLogger.log("vpnManager.connect: no session, returning", category: "ui")
            return
        }

        var options: [String: NSObject]? = nil
        if let config = configJSON {
            options = ["configContent": config as NSString]
        }

        TunnelFileLogger.log("vpnManager.connect: calling session.startTunnel", category: "ui")
        try session.startTunnel(options: options)
        TunnelFileLogger.log("vpnManager.connect: session.startTunnel returned", category: "ui")
    }

    /// Disable On Demand so iOS doesn't auto-reconnect after disconnect.
    func disableOnDemand() async {
        guard let m = manager, m.isOnDemandEnabled else { return }
        m.isOnDemandEnabled = false
        do {
            try await m.saveToPreferences()
        } catch {
            Self.logger.error("Failed to disable On Demand: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        userInitiatedDisconnect = true
        // Disable On Demand so iOS doesn't auto-reconnect after explicit disconnect
        if let m = manager, m.isOnDemandEnabled {
            m.isOnDemandEnabled = false
            m.saveToPreferences { error in
                if let error {
                    Self.logger.error("disconnect: saveToPreferences failed: \(error.localizedDescription)")
                }
            }
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

    /// Wait until the tunnel reports `.disconnected`. Used by server-switch to
    /// sequence disconnect → reconnect without polling. Times out after `timeout`.
    func waitUntilDisconnected(timeout: Duration = .seconds(5)) async {
        if status == .disconnected || status == .invalid { return }

        let deadline = ContinuousClock.now + timeout
        while status != .disconnected && status != .invalid {
            if ContinuousClock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Result of a connect watchdog: success, early failure, or timeout.
    /// `failed` means we observed the tunnel start (.connecting) and then fall
    /// back to .disconnected — usually a rejected config or killed extension.
    /// `timedOut` means we never reached .connected within the window.
    enum ConnectOutcome {
        case connected
        case failed
        case timedOut
        case permissionDenied
    }

    /// Wait until the tunnel reports `.connected`. Polls the @Observable
    /// `status` at 200ms and gives up after `timeout`. Detects rejected
    /// connects (connecting → disconnected) so the caller can show a real
    /// error instead of sitting forever.
    func waitUntilConnected(timeout: Duration = .seconds(30)) async -> ConnectOutcome {
        if status == .connected { return .connected }

        let deadline = ContinuousClock.now + timeout
        var sawConnecting = false
        // Give iOS a short grace window to flip out of .disconnected at the
        // very start — observer-driven updates can lag by one runloop.
        let startupGrace = ContinuousClock.now + .seconds(3)

        while ContinuousClock.now < deadline {
            switch status {
            case .connected:
                return .connected
            case .connecting, .reasserting:
                sawConnecting = true
            case .disconnecting:
                return .failed
            case .invalid:
                return .permissionDenied
            case .disconnected:
                if sawConnecting { return .failed }
                if ContinuousClock.now >= startupGrace { return .timedOut }
            @unknown default:
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return .timedOut
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
        ) { [weak self] notification in
            // Read status from notification object (avoids capturing MainActor-isolated self.manager)
            let newStatus = (notification.object as? NEVPNConnection)?.status ?? .disconnected
            Task { @MainActor [weak self] in
                self?.status = newStatus
            }
        }
        status = manager.connection.status
    }

    private func createManager() -> NETunnelProviderManager {
        let m = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppConstants.tunnelBundleID
        proto.serverAddress = AppConfig.vpnProfileDescription
        proto.providerConfiguration = [:]
        m.protocolConfiguration = proto
        m.localizedDescription = AppConfig.vpnProfileDescription
        m.isEnabled = true
        m.onDemandRules = []
        m.isOnDemandEnabled = false
        return m
    }
}
