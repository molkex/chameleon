import XCTest
@testable import MadFrogVPN

/// EXPIRED-PAYWALL-ON-CONNECT (2026-06-17). The connect gate: a CONNECT intent
/// requires an active subscription, else the paywall is shown instead of
/// toggling the tunnel. `mayConnect` is the pure decision — an absent/past
/// expiry is NOT coverage (mirrors the backend's hasActiveSubscription), but a
/// live StoreKit entitlement (isPremium) always allows it.
final class AppStateConnectGateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var future: Date { now.addingTimeInterval(86_400) }
    private var past: Date { now.addingTimeInterval(-86_400) }

    func testFutureExpiryMayConnect() {
        XCTAssertTrue(AppState.mayConnect(subscriptionExpire: future, isPremium: false, now: now))
    }

    func testPastExpiryGated() {
        XCTAssertFalse(AppState.mayConnect(subscriptionExpire: past, isPremium: false, now: now))
    }

    func testNilExpiryGated() {
        // Absent coverage = not "lifetime" → paywall.
        XCTAssertFalse(AppState.mayConnect(subscriptionExpire: nil, isPremium: false, now: now))
    }

    func testPremiumAlwaysConnectsEvenWithStaleBackendExpiry() {
        // A non-CIS Apple payer whose backend expiry hasn't synced (nil/past)
        // must NOT be blocked — the live StoreKit entitlement wins.
        XCTAssertTrue(AppState.mayConnect(subscriptionExpire: nil, isPremium: true, now: now))
        XCTAssertTrue(AppState.mayConnect(subscriptionExpire: past, isPremium: true, now: now))
    }

    func testExactlyNowIsNotActive() {
        // Boundary: expiry == now is past-or-equal → gated (strictly future).
        XCTAssertFalse(AppState.mayConnect(subscriptionExpire: now, isPremium: false, now: now))
    }
}
