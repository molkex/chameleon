import Foundation
import NetworkExtension

/// Pure decision logic extracted from `VPNManager` and `AppState` so the
/// branchy NE-orchestration cores are unit-testable without
/// NetworkExtension (which can't be instantiated or driven in a unit
/// test). Every function here is a behaviour-preserving extract-method:
/// the callers (`VPNManager`, `AppState`) read/write the live
/// NETunnelProviderManager + UserDefaults and just route on these.

// MARK: - VPNManager.connect — profile-adjustment guard

/// What `connect()` must change on the manager before starting the
/// tunnel: the profile must be enabled and On-Demand must be OFF (an
/// unconditional Connect rule otherwise makes the VPN un-disableable
/// from iOS Settings). `needsSave` is true iff either field actually
/// changes — so the warm path does no `saveToPreferences` round-trip,
/// matching the original inline `needsSave` accumulation.
struct ConnectProfileAdjustment: Equatable {
    var isEnabled: Bool
    var isOnDemandEnabled: Bool
    var needsSave: Bool
}

func connectProfileAdjustment(isEnabled: Bool, isOnDemandEnabled: Bool) -> ConnectProfileAdjustment {
    var needsSave = false
    var newEnabled = isEnabled
    var newOnDemand = isOnDemandEnabled
    if !isEnabled {
        newEnabled = true
        needsSave = true
    }
    if isOnDemandEnabled {
        newOnDemand = false
        needsSave = true
    }
    return ConnectProfileAdjustment(isEnabled: newEnabled, isOnDemandEnabled: newOnDemand, needsSave: needsSave)
}

// MARK: - VPNManager.setOnDemand — idempotency guard

/// `setOnDemand(enabled:)` is a no-op (no save round-trip) when the
/// manager is already in the requested state. This encodes the guard:
/// given the manager's current `isOnDemandEnabled` and whether its
/// `onDemandRules` already match the desired shape (exactly one
/// `NEOnDemandRuleConnect` when enabling, empty when disabling),
/// returns whether a `saveToPreferences` is needed.
///
/// `currentRulesMatchDesired` is computed by the caller from the live
/// `onDemandRules` (it needs the NE rule types); this just combines it
/// with the enabled-state check exactly as the original `guard` did.
func onDemandSaveNeeded(currentEnabled: Bool, currentRulesMatchDesired: Bool, desiredEnabled: Bool) -> Bool {
    !(currentEnabled == desiredEnabled && currentRulesMatchDesired)
}

// MARK: - VPNManager.waitUntilConnected — outcome mapping

/// The watchdog poll-loop's per-tick decision. Mirrors the `switch
/// status` inside `waitUntilConnected`: `nil` means "keep polling",
/// a non-nil `ConnectOutcomeKind` means "return this now".
///
/// `sawConnecting` tracks whether the tunnel was ever observed in
/// `.connecting`/`.reasserting` — a `.disconnected` after that is a
/// real failure, whereas a `.disconnected` before it (within the
/// startup grace window) is just observer lag and we keep waiting.
enum ConnectOutcomeKind: Equatable {
    case connected
    case failed
    case timedOut
    case permissionDenied
}

func connectOutcome(for status: NEVPNStatus, sawConnecting: Bool, pastStartupGrace: Bool) -> ConnectOutcomeKind? {
    switch status {
    case .connected:
        return .connected
    case .connecting, .reasserting:
        return nil  // keep polling; caller sets sawConnecting = true
    case .disconnecting:
        return .failed
    case .invalid:
        return .permissionDenied
    case .disconnected:
        if sawConnecting { return .failed }
        if pastStartupGrace { return .timedOut }
        return nil
    @unknown default:
        return nil
    }
}

// MARK: - AppState.handleStatus — status → effect mapping

/// Which branch of `handleStatus()` a given `NEVPNStatus` drives. The
/// `.connected` branch stamps/restores `vpnConnectedAtKey` and arms the
/// command client + On-Demand; the `.disconnected`/`.invalid` branch
/// clears `vpnConnectedAtKey` and may disable On-Demand; everything
/// else is a no-op (the original `default: break`).
enum VPNStatusEffect: Equatable {
    /// `.connected` — stamp/restore the connect timestamp, arm widgets.
    case markConnected
    /// `.disconnected` / `.invalid` — clear the timestamp, tear down.
    case markDisconnected
    /// `.connecting` / `.disconnecting` / `.reasserting` — no state change.
    case ignore
}

func vpnStatusEffect(for status: NEVPNStatus) -> VPNStatusEffect {
    switch status {
    case .connected:
        return .markConnected
    case .disconnected, .invalid:
        return .markDisconnected
    default:
        return .ignore
    }
}

// MARK: - AppState.awaitConnectionWithSilentRetry — retry decision

/// Build-36 silent-retry rule: only a `.timedOut` first attempt earns a
/// silent disconnect→reconnect→re-wait. Any other first outcome
/// (`.connected`, `.failed`, `.permissionDenied`) is returned straight
/// to the caller — there's nothing a retry would fix.
func shouldSilentlyRetryConnect(firstOutcome: ConnectOutcomeKind) -> Bool {
    firstOutcome == .timedOut
}

// MARK: - AppState.requestToggle — primer-vs-toggle gate

/// First-tap gate for the Connect button. When the user has never
/// approved the VPN profile (no saved NETunnelProviderManager) AND the
/// tunnel isn't already up, we show the pre-permission primer instead
/// of triggering iOS's system alert cold. Every other case proceeds
/// straight to `toggleVPN()`.
enum ToggleEntry: Equatable {
    case showPrimer
    case toggle
}

func toggleEntryDecision(isConnected: Bool, hasInstalledProfile: Bool) -> ToggleEntry {
    if !isConnected && !hasInstalledProfile {
        return .showPrimer
    }
    return .toggle
}
