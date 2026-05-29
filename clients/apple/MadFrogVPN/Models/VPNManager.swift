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

    // MARK: - LAUNCH-07 Auto-connect on Untrusted Wi-Fi

    /// Errors thrown by `applyAutoConnectRules` so the UI can show a real
    /// reason rather than a generic toast. `noManager` happens when the user
    /// hasn't approved the VPN profile yet — the Settings toggle still lets
    /// them queue their preference, but we can't install rules until the
    /// tunnel exists, so the call no-ops here. `saveFailed` wraps the
    /// underlying NEVPNError so the toast can include the system message.
    enum OnDemandError: Error {
        case noManager
        case saveFailed(Error)
    }

    /// Build + apply the LAUNCH-07 NEOnDemandRule chain. Pure no-op when no
    /// `NETunnelProviderManager` has been saved yet — the rules can't exist
    /// without a tunnel profile to attach them to, so the Settings UI is
    /// free to flip the toggle pre-permission; the rules will be installed
    /// the first time the user connects.
    ///
    /// Rule shape when `enabled == true`:
    ///   1. `NEOnDemandRuleIgnore` { interfaceTypeMatch: .wiFi, ssidMatch: trusted }
    ///        — On a known SSID, do nothing. We chose Ignore over Disconnect
    ///        so a manually-started session on the home network isn't torn.
    ///   2. `NEOnDemandRuleConnect` { interfaceTypeMatch: .wiFi }
    ///        — Any other Wi-Fi: bring the tunnel up.
    ///   3. (only if `includeCellular`) `NEOnDemandRuleConnect`
    ///      { interfaceTypeMatch: .cellular }
    ///        — Default OFF: cellular is opt-in (battery, data cap).
    ///
    /// When `enabled == false` we set `isOnDemandEnabled = false` AND clear
    /// `onDemandRules = []`. Apple's docs say `isOnDemandEnabled = false`
    /// alone is sufficient, but iOS has a long history of stale-rule bugs
    /// — leaving an unused chain on the profile has bitten users on iOS 14
    /// + iOS 15. Empty array is the safe state.
    func applyAutoConnectRules(
        enabled: Bool,
        trustedSSIDs: [String],
        includeCellular: Bool
    ) async throws {
        guard let m = manager else {
            // Caller already persisted the user's preference via ConfigStore;
            // VPNManager will pick the rules up on the first `connect()` call.
            throw OnDemandError.noManager
        }

        let rules = Self.buildOnDemandRules(
            enabled: enabled,
            trustedSSIDs: trustedSSIDs,
            includeCellular: includeCellular
        )
        m.onDemandRules = rules
        m.isOnDemandEnabled = enabled

        do {
            try await m.saveToPreferences()
            // saveToPreferences invalidates the existing in-memory snapshot;
            // re-load to keep .connection observers wired.
            try await m.loadFromPreferences()
            Self.logger.info("applyAutoConnectRules: enabled=\(enabled) trusted=\(trustedSSIDs.count) cellular=\(includeCellular)")
        } catch {
            throw OnDemandError.saveFailed(error)
        }
    }

    /// Pure rule-array builder. Public + `nonisolated` so unit tests can
    /// drive it without standing up a full VPNManager. Apple's `NEOnDemandRule`
    /// types are Sendable-compatible enough for use here (they're NSObject
    /// subclasses with simple property setters).
    nonisolated static func buildOnDemandRules(
        enabled: Bool,
        trustedSSIDs: [String],
        includeCellular: Bool
    ) -> [NEOnDemandRule] {
        guard enabled else { return [] }

        var rules: [NEOnDemandRule] = []

        // Trim + dedupe defensively — ConfigStore.addTrustedSSID already does
        // this on write, but we can be invoked with externally-supplied data
        // (tests, future watchOS sync) so don't trust the input shape.
        let trimmed = trustedSSIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Rule 1: trusted SSID → ignore. Skipped entirely when the list is
        // empty — an Ignore rule with `ssidMatch = []` would mean "match no
        // SSID" and the Connect rule below would fire on every Wi-Fi anyway,
        // but pruning the empty rule keeps the rule chain tidy.
        if !trimmed.isEmpty {
            let ignore = NEOnDemandRuleIgnore()
            ignore.interfaceTypeMatch = .wiFi
            ignore.ssidMatch = trimmed
            rules.append(ignore)
        }

        // Rule 2: any other Wi-Fi → connect.
        let connectWiFi = NEOnDemandRuleConnect()
        connectWiFi.interfaceTypeMatch = .wiFi
        rules.append(connectWiFi)

        // Rule 3 (optional): cellular → connect. iOS-only — macOS has no
        // cellular interface, so `.cellular` is unavailable there.
        #if os(iOS)
        if includeCellular {
            let connectCellular = NEOnDemandRuleConnect()
            connectCellular.interfaceTypeMatch = .cellular
            rules.append(connectCellular)
        }
        #endif

        return rules
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
    ///
    /// Audit MED-006 (2026-05-26): bounded with a 5s timeout. The system
    /// `sendProviderMessage` continuation will hang forever if the
    /// extension never calls the completion handler (jetsam'd between
    /// receiving the message and replying, or its handleAppMessage
    /// implementation is missing a callback path). Without a timeout
    /// any UI task awaiting this — server selection apply, ping refresh,
    /// stats read — wedges silently. We surface that as a thrown
    /// NSError(.timedOut) so callers can fall back gracefully.
    func sendMessage(_ data: Data) async throws -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession else { return nil }
        return try await Self.raceWithTimeout(timeout: .seconds(5)) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                do {
                    try session.sendProviderMessage(data) { response in
                        continuation.resume(returning: response)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// build-88 testability extract (audit MED-006): race `operation`
    /// against a timeout and throw `NSError(NSURLErrorDomain,
    /// NSURLErrorTimedOut)` if the timeout wins. Pulled out of
    /// `sendMessage` so the timeout semantics can be unit-tested without
    /// touching `NETunnelProviderSession` (which can't be constructed in
    /// a test environment). The error shape is preserved exactly so
    /// callers that key on `URLError.timedOut` still match.
    static func raceWithTimeout<T: Sendable>(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorTimedOut,
                    userInfo: [NSLocalizedDescriptionKey: "operation timed out"]
                )
            }
            // group.next() returns the first task to complete — either the
            // real work or the timeout. Cancelling the rest stops the loser
            // immediately so we don't leak a sleeping Task.
            let result = try await group.next()!
            group.cancelAll()
            return result
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
