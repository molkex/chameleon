import XCTest
@testable import MadFrogVPN

/// EXPIRED-PAYWALL-ON-CONNECT (2026-06-17) + CLIENT-ENTITLEMENT-GATE fix
/// (2026-07-12). The connect gate: a CONNECT intent requires an active
/// subscription, else the paywall is shown instead of toggling the tunnel.
/// `mayConnect` is the pure decision. Backend `subscription_expiry` is
/// authoritative whenever known (all 4 products are NonRenewingSubscription,
/// so StoreKit reports a nil expirationDate for them and `isPremium` stays
/// true forever after any purchase — it cannot encode "still within the paid
/// window"). `isPremium` is consulted only when the backend expiry is nil, as
/// a fresh-purchase fallback before the backend sync lands.
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
        // Absent coverage + no live entitlement = not "lifetime" → paywall.
        XCTAssertFalse(AppState.mayConnect(subscriptionExpire: nil, isPremium: false, now: now))
    }

    func testPastExpiryBlocksEvenWithPremiumFlag() {
        // CLIENT-ENTITLEMENT-GATE regression (2026-07-12): all 4 products are
        // NonRenewingSubscription, so StoreKit's expirationDate is nil and
        // `isPremium` (isActiveEntitlement) stays true forever after any
        // purchase. A churned user's backend expiry is a PAST date (not
        // nil) — the backend expiry must win and block the connect, even
        // though the stale/permanent `isPremium` flag says true.
        XCTAssertFalse(AppState.mayConnect(subscriptionExpire: past, isPremium: true, now: now))
    }

    func testNilExpiryWithPremiumIsFreshPurchaseFallback() {
        // Right after a fresh purchase, before the backend has synced an
        // expiry (nil), the live StoreKit entitlement is the only signal we
        // have — it must allow the connect.
        XCTAssertTrue(AppState.mayConnect(subscriptionExpire: nil, isPremium: true, now: now))
    }

    func testExactlyNowIsNotActive() {
        // Boundary: expiry == now is past-or-equal → gated (strictly future).
        XCTAssertFalse(AppState.mayConnect(subscriptionExpire: now, isPremium: false, now: now))
    }
}
