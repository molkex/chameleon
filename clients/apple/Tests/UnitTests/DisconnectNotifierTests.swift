import XCTest
import NetworkExtension
@testable import MadFrogVPN

/// LAUNCH-08 regression guards for `DisconnectNotifier.decide(...)` — the
/// pure transition function that decides whether an OS-initiated tunnel
/// drop should trigger a local notification.
///
/// We can't unit-test the actual UNUserNotificationCenter scheduling
/// without standing up a notification server, but the decision logic is
/// pure and pinning it here keeps the matrix honest:
///
///   * connecting → disconnected (failed handshake)        → noop
///   * connected → disconnected, userInitiated == true     → noop
///   * connected → disconnected, userInitiated == false    → FIRE
///   * disconnecting → disconnected, snapshot == true      → noop
///   * disconnecting → disconnected, snapshot == false     → FIRE
///   * any of the above while isAppActive == true          → noop
///   * any other transition                                → noop
///
/// Snapshot logic note: `decide(...)` takes BOTH the live + snapshot flag
/// because the call site has to pick which one is authoritative for a
/// given transition. For `disconnecting → disconnected` the snapshot wins
/// (it was captured before any pending reconnect could reset the live
/// flag). For `connected → .disconnected` directly (no intermediate) the
/// live value is the only signal available.
final class DisconnectNotifierTests: XCTestCase {

    func testFailedHandshakeIsSilent() {
        let decision = DisconnectNotifier.decide(
            previous: .connecting,
            next: .disconnected,
            userInitiatedSnapshot: false,
            userInitiatedLive: false,
            isAppActive: false
        )
        XCTAssertEqual(decision, .noop,
                       ".connecting → .disconnected MUST be silent: the toggleVPN watchdog already shows a UI error")
    }

    func testConnectedToDisconnectingIsSilent() {
        // Always silent — we wait for .disconnected before firing.
        let decision = DisconnectNotifier.decide(
            previous: .connected,
            next: .disconnecting,
            userInitiatedSnapshot: false,
            userInitiatedLive: false,
            isAppActive: false
        )
        XCTAssertEqual(decision, .noop)
    }

    func testConnectedDirectlyToDisconnected_NotUserInitiated_Fires() {
        // OS killed the extension or server dropped — no intermediate
        // .disconnecting transition; live flag is authoritative.
        let decision = DisconnectNotifier.decide(
            previous: .connected,
            next: .disconnected,
            userInitiatedSnapshot: false,
            userInitiatedLive: false,
            isAppActive: false
        )
        XCTAssertEqual(decision, .fireNotification)
    }

    func testConnectedDirectlyToDisconnected_UserInitiated_Silent() {
        let decision = DisconnectNotifier.decide(
            previous: .connected,
            next: .disconnected,
            userInitiatedSnapshot: false,
            userInitiatedLive: true,
            isAppActive: false
        )
        XCTAssertEqual(decision, .noop)
    }

    func testDisconnectingToDisconnected_SnapshotUser_Silent() {
        // User tapped disconnect → snapshot captured during .disconnecting,
        // even if the live flag has since been reset by a quick reconnect.
        let decision = DisconnectNotifier.decide(
            previous: .disconnecting,
            next: .disconnected,
            userInitiatedSnapshot: true,
            userInitiatedLive: false, // racy live flag — snapshot wins
            isAppActive: false
        )
        XCTAssertEqual(decision, .noop,
                       "snapshot must override live flag — a racy reconnect MUST NOT bypass the user-initiated suppression")
    }

    func testDisconnectingToDisconnected_SnapshotNotUser_Fires() {
        let decision = DisconnectNotifier.decide(
            previous: .disconnecting,
            next: .disconnected,
            userInitiatedSnapshot: false,
            userInitiatedLive: false,
            isAppActive: false
        )
        XCTAssertEqual(decision, .fireNotification)
    }

    func testForegroundSuppressesEverything() {
        // Even an OS-initiated drop is silent if the app is in the foreground.
        let decision = DisconnectNotifier.decide(
            previous: .connected,
            next: .disconnected,
            userInitiatedSnapshot: false,
            userInitiatedLive: false,
            isAppActive: true
        )
        XCTAssertEqual(decision, .noop,
                       "foreground = the UI shows the state directly, a banner is redundant")
    }

    func testInvalidIsNoop() {
        // Extension uninstalled / profile gone — not a tunnel drop.
        let decision = DisconnectNotifier.decide(
            previous: .connected,
            next: .invalid,
            userInitiatedSnapshot: false,
            userInitiatedLive: false,
            isAppActive: false
        )
        XCTAssertEqual(decision, .noop)
    }

    /// End-to-end driver of the state machine via `record(...)` — ensures
    /// the bookkeeping (previousStatus, pendingDisconnectWasUserInitiated)
    /// updates correctly across a full disconnect cycle.
    @MainActor
    func testRecord_OSDropAcrossDisconnectingThenDisconnected() {
        let notifier = DisconnectNotifier()
        notifier.setAppActive(false)

        // Seed → connected
        notifier.record(status: .connected, userInitiatedDisconnect: false)
        XCTAssertEqual(notifier.previousStatus, .connected)
        XCTAssertFalse(notifier.pendingDisconnectWasUserInitiated)

        // connected → disconnecting: server dropped, user flag is false.
        notifier.record(status: .disconnecting, userInitiatedDisconnect: false)
        XCTAssertEqual(notifier.previousStatus, .disconnecting)
        XCTAssertFalse(notifier.pendingDisconnectWasUserInitiated,
                       "snapshot captured: not user-initiated")

        // disconnecting → disconnected: should fire (we can't observe the
        // actual UN call, but at minimum the bookkeeping must reset).
        notifier.record(status: .disconnected, userInitiatedDisconnect: false)
        XCTAssertEqual(notifier.previousStatus, .disconnected)
        XCTAssertFalse(notifier.pendingDisconnectWasUserInitiated,
                       "snapshot must reset on .disconnected so the next cycle starts clean")
    }

    @MainActor
    func testRecord_UserInitiatedDisconnectIsSnapshotted() {
        let notifier = DisconnectNotifier()
        notifier.setAppActive(false)

        notifier.record(status: .connected, userInitiatedDisconnect: false)
        // User taps Disconnect → live flag goes true BEFORE .disconnecting.
        notifier.record(status: .disconnecting, userInitiatedDisconnect: true)
        XCTAssertTrue(notifier.pendingDisconnectWasUserInitiated,
                      "snapshot must capture the user flag at .disconnecting time")

        // Now imagine a fast reconnect resets vpnManager.userInitiatedDisconnect
        // before .disconnected arrives — the live flag passed in here is false,
        // but the snapshot is still true.
        notifier.record(status: .disconnected, userInitiatedDisconnect: false)
        XCTAssertFalse(notifier.pendingDisconnectWasUserInitiated)
        XCTAssertEqual(notifier.previousStatus, .disconnected)
    }
}
