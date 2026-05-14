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
    nonisolated private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VPN", category: "VPNManager")
    private var statusObserver: Any?
    /// Set to true when disconnect() is called from the app, reset on connect().
    /// Prevents disabling On Demand when iOS Settings or On Demand itself triggers disconnect.
    private(set) var userInitiatedDisconnect = false

    var isConnected: Bool { status == .connected }
    var isProcessing: Bool { status == .connecting || status == .disconnecting || status == .reasserting }

    /// True once the user has approved the VPN profile — i.e. a
    /// NETunnelProviderManager has been saved to their device. We use this to
    /// show a pre-permission primer on first Connect: iOS's system alert is
    /// jarring without context, and App Review increasingly flags apps that
    /// trigger it cold.
    var hasInstalledProfile: Bool { manager != nil }

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
            let adjustment = connectProfileAdjustment(isEnabled: m.isEnabled, isOnDemandEnabled: m.isOnDemandEnabled)
            m.isEnabled = adjustment.isEnabled
            m.isOnDemandEnabled = adjustment.isOnDemandEnabled
            let needsSave = adjustment.needsSave
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

    /// launch-06: install or clear iOS Connect-On-Demand.
    ///
    /// When `enabled`, sets a single unconditional `NEOnDemandRuleConnect`
    /// so iOS re-establishes the tunnel after network changes or an
    /// extension crash — the user's "Auto-connect" preference.
    ///
    /// The well-known footgun (an unconditional Connect rule makes the VPN
    /// un-disableable from iOS Settings) is neutralised elsewhere:
    /// `disconnect()` clears `isOnDemandEnabled` on an explicit in-app
    /// stop, and the `userStoppedVPN` → `disableOnDemand()` path clears it
    /// when the user flips the VPN off in iOS Settings. On-Demand re-arms
    /// on the next manual connect. Net effect: auto-reconnect on the 95%
    /// path, but an explicit stop always truly stops.
    ///
    /// No-op (no save round-trip) when the manager is already in the
    /// requested state — safe to call on every connect / toggle.
    func setOnDemand(enabled: Bool) async {
        guard let m = manager else { return }
        let rulesMatch = enabled
            ? (m.onDemandRules?.count == 1 && m.onDemandRules?.first is NEOnDemandRuleConnect)
            : (m.onDemandRules?.isEmpty ?? true)
        if !onDemandSaveNeeded(currentEnabled: m.isOnDemandEnabled, currentRulesMatchDesired: rulesMatch, desiredEnabled: enabled) {
            return
        }
        m.onDemandRules = enabled ? [NEOnDemandRuleConnect()] : []
        m.isOnDemandEnabled = enabled
        do {
            try await m.saveToPreferences()
            TunnelFileLogger.log("vpnManager.setOnDemand: enabled=\(enabled)", category: "ui")
        } catch {
            Self.logger.error("setOnDemand(\(enabled)) failed: \(error.localizedDescription)")
            TunnelFileLogger.log("vpnManager.setOnDemand: FAILED enabled=\(enabled) — \(error.localizedDescription)", category: "ui")
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

        /// Map from the pure `ConnectOutcomeKind` produced by
        /// `connectOutcome(for:sawConnecting:pastStartupGrace:)`. Total,
        /// 1:1 — the two enums are deliberately the same shape; the kind
        /// type just lives in `Shared/` so it's testable without
        /// `@MainActor`-isolated `VPNManager`.
        init(_ kind: ConnectOutcomeKind) {
            switch kind {
            case .connected: self = .connected
            case .failed: self = .failed
            case .timedOut: self = .timedOut
            case .permissionDenied: self = .permissionDenied
            }
        }

        /// Reverse of `init(_:)` — lets callers route on the pure
        /// `Shared/` decision helpers (e.g. `shouldSilentlyRetryConnect`).
        var kind: ConnectOutcomeKind {
            switch self {
            case .connected: return .connected
            case .failed: return .failed
            case .timedOut: return .timedOut
            case .permissionDenied: return .permissionDenied
            }
        }
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
            if status == .connecting || status == .reasserting {
                sawConnecting = true
            }
            if let kind = connectOutcome(
                for: status,
                sawConnecting: sawConnecting,
                pastStartupGrace: ContinuousClock.now >= startupGrace
            ) {
                return ConnectOutcome(kind)
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
