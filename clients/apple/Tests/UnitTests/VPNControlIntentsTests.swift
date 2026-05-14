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
}
