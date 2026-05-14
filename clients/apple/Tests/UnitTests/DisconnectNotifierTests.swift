import XCTest
import NetworkExtension
@testable import MadFrogVPN

/// launch-07: pins the notify/stay-silent policy for unexpected
/// disconnects. `unexpectedBody(for:)` is the contract — a non-nil body
/// means "post a banner, the user lost protection without asking".
final class DisconnectNotifierTests: XCTestCase {

    // Reasons that mean "you lost protection and didn't choose to" — must
    // produce a banner body.
    func testNotifiesOnUnexpectedLossOfProtection() {
        let shouldNotify: [NEProviderStopReason] = [
            .providerFailed,
            .connectionFailed,
            .noNetworkAvailable,
            .unrecoverableNetworkChange,
        ]
        for reason in shouldNotify {
            XCTAssertNotNil(
                DisconnectNotifier.unexpectedBody(for: reason),
                "reason \(reason.rawValue) is an unexpected loss of protection — must notify"
            )
        }
    }

    // User-intended or self-resolving stops — must stay silent.
    func testSilentOnExpectedStops() {
        let shouldBeSilent: [NEProviderStopReason] = [
            .none,
            .userInitiated,
            .providerDisabled,
            .authenticationCanceled,
            .idleTimeout,
            .configurationDisabled,
            .configurationRemoved,
            .superceded,
            .userLogout,
            .userSwitch,
            .sleep,
            .appUpdate,
        ]
        for reason in shouldBeSilent {
            XCTAssertNil(
                DisconnectNotifier.unexpectedBody(for: reason),
                "reason \(reason.rawValue) is expected/self-resolving — must stay silent"
            )
        }
    }

    // The two notify buckets carry distinct copy (crash/connection vs
    // network-change) so the user gets a useful hint, not a generic string.
    func testBodyDistinguishesCrashFromNetworkChange() {
        let crash = DisconnectNotifier.unexpectedBody(for: .providerFailed)
        let netChange = DisconnectNotifier.unexpectedBody(for: .noNetworkAvailable)
        XCTAssertNotNil(crash)
        XCTAssertNotNil(netChange)
        XCTAssertNotEqual(crash, netChange, "crash and network-change reasons should read differently")
    }
}
