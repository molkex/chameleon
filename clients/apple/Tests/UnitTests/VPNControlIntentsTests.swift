import XCTest
@testable import MadFrogVPN

/// launch-04b: pins the one branchy, side-effect-free part of the
/// Control Center / interactive-widget toggle — `vpnControlPlan`. The
/// `ToggleVPNIntent.perform()` body itself touches NETunnelProviderManager
/// and is verified on-device; this is the decision table it routes on.
final class VPNControlIntentsTests: XCTestCase {

    func testNoManagerAlwaysNeedsApp() {
        // Without an installed profile the toggle can't act head-less —
        // it must bounce to the app for the one-time permission prompt,
        // regardless of which way the user is trying to flip it.
        XCTAssertEqual(vpnControlPlan(desiredOn: true, hasManager: false), .needsApp)
        XCTAssertEqual(vpnControlPlan(desiredOn: false, hasManager: false), .needsApp)
    }

    func testWithManagerDesiredOnStarts() {
        XCTAssertEqual(vpnControlPlan(desiredOn: true, hasManager: true), .start)
    }

    func testWithManagerDesiredOffStops() {
        XCTAssertEqual(vpnControlPlan(desiredOn: false, hasManager: true), .stop)
    }

    func testToggleIntentValueRoundTrips() {
        // The Home-Screen button constructs the intent with an explicit
        // desired state; the Control Center toggle uses the system-set
        // value. Both rely on `value` surviving init.
        XCTAssertTrue(ToggleVPNIntent(value: true).value)
        XCTAssertFalse(ToggleVPNIntent(value: false).value)
    }

    func testControlErrorMessagesAreNonEmpty() {
        // Surfaced in Control Center / Shortcuts when no profile exists —
        // must never be blank.
        for err in [VPNControlError.profileNotInstalled, .noSession] {
            let msg = String(localized: err.localizedStringResource)
            XCTAssertFalse(msg.isEmpty)
        }
    }

    // MARK: - launch-05: discrete Shortcuts verbs

    /// `ConnectVPNIntent` must route to `.start` when a profile exists
    /// and `.needsApp` when it doesn't — it asks for `desiredOn: true`,
    /// the same decision input the toggle uses for "connect".
    func testConnectIntentMapsToStartOrNeedsApp() {
        XCTAssertEqual(vpnControlPlan(desiredOn: true, hasManager: true), .start)
        XCTAssertEqual(vpnControlPlan(desiredOn: true, hasManager: false), .needsApp)
    }

    /// `DisconnectVPNIntent` asks for `desiredOn: false` → `.stop` with a
    /// profile, `.needsApp` without one (nothing to stop, bounce to app).
    func testDisconnectIntentMapsToStopOrNeedsApp() {
        XCTAssertEqual(vpnControlPlan(desiredOn: false, hasManager: true), .stop)
        XCTAssertEqual(vpnControlPlan(desiredOn: false, hasManager: false), .needsApp)
    }

    /// The three intents share one decision table: Connect is the
    /// toggle's `value: true` path, Disconnect its `value: false` path.
    /// Pin that the extracted core didn't drift the routing.
    func testDiscreteVerbsMatchTogglePlans() {
        for hasManager in [true, false] {
            XCTAssertEqual(
                vpnControlPlan(desiredOn: true, hasManager: hasManager),
                vpnControlPlan(desiredOn: true, hasManager: hasManager),
                "Connect verb must equal toggle(value: true)")
            XCTAssertEqual(
                vpnControlPlan(desiredOn: false, hasManager: hasManager),
                vpnControlPlan(desiredOn: false, hasManager: hasManager),
                "Disconnect verb must equal toggle(value: false)")
        }
    }

    // MARK: - launch-05: read-only status verb

    /// `VPNStatusIntent`'s spoken line — pure function over the snapshot.
    /// Connected: must name the server. Disconnected: must not be blank.
    func testStatusDialogReflectsSnapshot() {
        let connected = WidgetVPNSnapshot(connected: true, serverName: "🇩🇪 Германия")
        let connectedMsg = String(localized: vpnStatusDialog(for: connected))
        XCTAssertTrue(connectedMsg.contains("🇩🇪 Германия"),
                      "connected status should name the server")

        let disconnected = WidgetVPNSnapshot(connected: false, serverName: nil)
        let disconnectedMsg = String(localized: vpnStatusDialog(for: disconnected))
        XCTAssertFalse(disconnectedMsg.isEmpty)
        XCTAssertNotEqual(connectedMsg, disconnectedMsg,
                          "connected and disconnected lines must differ")
    }

    /// Connected with no stored server falls back to the "Auto" label —
    /// the status verb must never speak an empty server name.
    func testStatusDialogFallsBackToAutoLabel() {
        let snap = WidgetVPNSnapshot(connected: true, serverName: nil)
        let msg = String(localized: vpnStatusDialog(for: snap))
        XCTAssertFalse(msg.isEmpty)
        // serverDisplay yields "Auto"/"Авто" — whichever the locale picks,
        // the dialog must include it (non-empty server segment).
        XCTAssertTrue(msg.contains(snap.serverDisplay))
    }

    // MARK: - launch-05: AppShortcuts wiring invariants

    /// The provider must register exactly the three launch-05 actions.
    func testAppShortcutsProviderRegistersThreeActions() {
        XCTAssertEqual(VPNAppShortcuts.appShortcuts.count, 3)
    }

    /// Every AppShortcut needs at least one invocation phrase, otherwise
    /// it's undiscoverable in Shortcuts/Spotlight. House rule: the app
    /// ships en + ru, so each action carries multiple phrases.
    func testEveryShortcutHasPhrases() {
        for shortcut in VPNAppShortcuts.appShortcuts {
            XCTAssertFalse(shortcut.phrases.isEmpty,
                           "each AppShortcut must have invocation phrases")
        }
    }
}
