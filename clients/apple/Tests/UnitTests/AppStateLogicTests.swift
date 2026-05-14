import XCTest
import NetworkExtension
@testable import MadFrogVPN

/// test-coverage-hardening: pins the pure decision cores extracted from
/// `AppState` — the central UI state machine. `AppState` itself is
/// `@MainActor @Observable` and leans on NETunnelProviderManager via
/// `VPNManager`, so the branchy logic is extracted into `Shared/` and
/// tested here without spinning up the full object:
///
///  - `vpnStatusEffect` — handleStatus()'s NEVPNStatus → branch
///    mapping: which statuses stamp/clear `vpnConnectedAtKey` and arm
///    or tear down the command client / On-Demand.
///  - `shouldSilentlyRetryConnect` — the build-36 watchdog rule: only
///    a timed-out first attempt earns a silent disconnect→reconnect.
///  - `toggleEntryDecision` — requestToggle()'s first-tap gate:
///    pre-permission primer vs straight toggle.
///
/// The side-effecting orchestration (UserDefaults App-Group writes,
/// WidgetCenter reload, Task spawning) stays on-device-verified.
final class AppStateLogicTests: XCTestCase {

    // MARK: - vpnStatusEffect (handleStatus routing)

    func testStatusEffect_connectedMarksConnected() {
        // .connected is the only status that stamps/restores
        // vpnConnectedAtKey and clears the userStoppedVPN flag.
        XCTAssertEqual(vpnStatusEffect(for: .connected), .markConnected)
    }

    func testStatusEffect_disconnectedAndInvalidMarkDisconnected() {
        // Both .disconnected and .invalid clear vpnConnectedAtKey and
        // tear down the command client + traffic monitor.
        XCTAssertEqual(vpnStatusEffect(for: .disconnected), .markDisconnected)
        XCTAssertEqual(vpnStatusEffect(for: .invalid), .markDisconnected)
    }

    func testStatusEffect_transientStatusesIgnored() {
        // .connecting / .disconnecting / .reasserting must NOT touch the
        // App-Group keys — the original handleStatus() `default: break`.
        // In particular .reasserting must not clear vpnConnectedAt: the
        // session timer has to survive a network handover.
        XCTAssertEqual(vpnStatusEffect(for: .connecting), .ignore)
        XCTAssertEqual(vpnStatusEffect(for: .disconnecting), .ignore)
        XCTAssertEqual(vpnStatusEffect(for: .reasserting), .ignore)
    }

    func testStatusEffect_isTotalOverKnownStatuses() {
        // Every NEVPNStatus maps to exactly one effect — no status falls
        // through unhandled.
        let all: [NEVPNStatus] = [.invalid, .disconnected, .connecting, .connected, .reasserting, .disconnecting]
        for s in all {
            _ = vpnStatusEffect(for: s)  // must not trap
        }
    }

    // MARK: - shouldSilentlyRetryConnect (watchdog silent retry)

    func testSilentRetry_onlyTimeoutRetries() {
        // Build-36: a timed-out first attempt is the one case a silent
        // disconnect→1s→reconnect can fix (libbox cold-start on LTE can
        // take 9-15s and just barely miss the 18s window).
        XCTAssertTrue(shouldSilentlyRetryConnect(firstOutcome: .timedOut))
    }

    func testSilentRetry_otherOutcomesReturnImmediately() {
        // .connected — already done; .failed / .permissionDenied — a
        // retry would change nothing, surface the error now.
        XCTAssertFalse(shouldSilentlyRetryConnect(firstOutcome: .connected))
        XCTAssertFalse(shouldSilentlyRetryConnect(firstOutcome: .failed))
        XCTAssertFalse(shouldSilentlyRetryConnect(firstOutcome: .permissionDenied))
    }

    // MARK: - toggleEntryDecision (requestToggle first-tap gate)

    func testToggleEntry_firstEverTap_showsPrimer() {
        // No saved profile and not connected → show the pre-permission
        // primer instead of triggering iOS's system alert cold.
        XCTAssertEqual(toggleEntryDecision(isConnected: false, hasInstalledProfile: false), .showPrimer)
    }

    func testToggleEntry_profileInstalled_togglesDirectly() {
        XCTAssertEqual(toggleEntryDecision(isConnected: false, hasInstalledProfile: true), .toggle)
    }

    func testToggleEntry_alreadyConnected_togglesDirectly() {
        // Connected implies a profile exists; tapping to disconnect must
        // never bounce through the primer — even if hasInstalledProfile
        // somehow read false, "connected" wins.
        XCTAssertEqual(toggleEntryDecision(isConnected: true, hasInstalledProfile: false), .toggle)
        XCTAssertEqual(toggleEntryDecision(isConnected: true, hasInstalledProfile: true), .toggle)
    }
}
