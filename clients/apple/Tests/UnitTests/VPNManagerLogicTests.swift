import XCTest
import NetworkExtension
@testable import MadFrogVPN

/// test-coverage-hardening: pins the pure decision cores extracted from
/// `VPNManager` (the NETunnelProviderManager lifecycle wrapper, which
/// can't be instantiated in a unit test):
///
///  - `connectProfileAdjustment` — connect()'s "enable profile, kill
///    On-Demand, save only if something changed" guard.
///  - `onDemandSaveNeeded` — setOnDemand()'s idempotency guard (no
///    save round-trip when already in the requested state).
///  - `connectOutcome` — waitUntilConnected()'s watchdog poll-loop
///    status → outcome mapping, including the sawConnecting / startup
///    grace interaction.
///
/// The NE-touching orchestration (saveToPreferences, startTunnel,
/// removeFromPreferences) stays on-device-verified.
final class VPNManagerLogicTests: XCTestCase {

    // MARK: - connectProfileAdjustment

    func testConnectAdjustment_warmPath_noSave() {
        // Profile already enabled, On-Demand already off → connect() must
        // not do a saveToPreferences round-trip.
        let a = connectProfileAdjustment(isEnabled: true, isOnDemandEnabled: false)
        XCTAssertEqual(a, ConnectProfileAdjustment(isEnabled: true, isOnDemandEnabled: false, needsSave: false))
    }

    func testConnectAdjustment_disabledProfile_enablesAndSaves() {
        let a = connectProfileAdjustment(isEnabled: false, isOnDemandEnabled: false)
        XCTAssertEqual(a, ConnectProfileAdjustment(isEnabled: true, isOnDemandEnabled: false, needsSave: true))
    }

    func testConnectAdjustment_onDemandOn_clearsAndSaves() {
        // An unconditional On-Demand Connect rule makes the VPN
        // un-disableable from iOS Settings — connect() must clear it.
        let a = connectProfileAdjustment(isEnabled: true, isOnDemandEnabled: true)
        XCTAssertEqual(a, ConnectProfileAdjustment(isEnabled: true, isOnDemandEnabled: false, needsSave: true))
    }

    func testConnectAdjustment_bothWrong_fixesBothOneSave() {
        let a = connectProfileAdjustment(isEnabled: false, isOnDemandEnabled: true)
        XCTAssertEqual(a, ConnectProfileAdjustment(isEnabled: true, isOnDemandEnabled: false, needsSave: true))
    }

    // MARK: - onDemandSaveNeeded

    func testOnDemandSave_alreadyEnabledWithMatchingRules_noSave() {
        XCTAssertFalse(onDemandSaveNeeded(currentEnabled: true, currentRulesMatchDesired: true, desiredEnabled: true),
                       "already in the requested state — setOnDemand must be a no-op")
    }

    func testOnDemandSave_alreadyDisabledWithEmptyRules_noSave() {
        XCTAssertFalse(onDemandSaveNeeded(currentEnabled: false, currentRulesMatchDesired: true, desiredEnabled: false))
    }

    func testOnDemandSave_enabledStateMatchesButRulesDont_save() {
        // isOnDemandEnabled already true, but the rules array is the
        // wrong shape (e.g. empty, or a non-Connect rule) — must re-save.
        XCTAssertTrue(onDemandSaveNeeded(currentEnabled: true, currentRulesMatchDesired: false, desiredEnabled: true))
    }

    func testOnDemandSave_enablingFromOff_save() {
        XCTAssertTrue(onDemandSaveNeeded(currentEnabled: false, currentRulesMatchDesired: false, desiredEnabled: true))
    }

    func testOnDemandSave_disablingFromOn_save() {
        XCTAssertTrue(onDemandSaveNeeded(currentEnabled: true, currentRulesMatchDesired: false, desiredEnabled: false))
    }

    // MARK: - connectOutcome (watchdog poll loop)

    func testConnectOutcome_connected() {
        XCTAssertEqual(connectOutcome(for: .connected, sawConnecting: false, pastStartupGrace: false), .connected)
        XCTAssertEqual(connectOutcome(for: .connected, sawConnecting: true, pastStartupGrace: true), .connected)
    }

    func testConnectOutcome_connectingKeepsPolling() {
        XCTAssertNil(connectOutcome(for: .connecting, sawConnecting: false, pastStartupGrace: false),
                     ".connecting → keep polling (nil)")
        XCTAssertNil(connectOutcome(for: .reasserting, sawConnecting: true, pastStartupGrace: true),
                     ".reasserting → keep polling (nil)")
    }

    func testConnectOutcome_disconnectingIsFailure() {
        XCTAssertEqual(connectOutcome(for: .disconnecting, sawConnecting: false, pastStartupGrace: false), .failed)
    }

    func testConnectOutcome_invalidIsPermissionDenied() {
        XCTAssertEqual(connectOutcome(for: .invalid, sawConnecting: true, pastStartupGrace: true), .permissionDenied)
    }

    func testConnectOutcome_disconnectedAfterConnecting_isFailure() {
        // We observed the tunnel start then fall back — a rejected config
        // or killed extension. Real failure, not observer lag.
        XCTAssertEqual(connectOutcome(for: .disconnected, sawConnecting: true, pastStartupGrace: false), .failed)
        XCTAssertEqual(connectOutcome(for: .disconnected, sawConnecting: true, pastStartupGrace: true), .failed)
    }

    func testConnectOutcome_disconnectedWithinStartupGrace_keepsPolling() {
        // .disconnected before ever seeing .connecting AND still inside the
        // 3s startup grace → just observer lag, keep waiting.
        XCTAssertNil(connectOutcome(for: .disconnected, sawConnecting: false, pastStartupGrace: false))
    }

    func testConnectOutcome_disconnectedPastStartupGrace_timesOut() {
        // Never saw .connecting and the grace window elapsed → the tunnel
        // never even tried to come up. Timeout.
        XCTAssertEqual(connectOutcome(for: .disconnected, sawConnecting: false, pastStartupGrace: true), .timedOut)
    }

    // MARK: - ConnectOutcome <-> ConnectOutcomeKind round-trip

    func testConnectOutcomeKindRoundTrips() {
        for kind in [ConnectOutcomeKind.connected, .failed, .timedOut, .permissionDenied] {
            XCTAssertEqual(VPNManager.ConnectOutcome(kind).kind, kind,
                           "the nested ConnectOutcome and the Shared ConnectOutcomeKind must stay 1:1")
        }
    }
}
