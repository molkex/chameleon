import XCTest
@testable import MadFrogVPN

/// Pins the pure entitlement-active decision extracted from `SubscriptionManager`
/// (`isActiveEntitlement`). The StoreKit-coupled orchestration
/// (`updatePremiumStatus`, `reconcileEntitlementsSilently`, `purchase`) walks
/// `Transaction.currentEntitlements` and can't be instantiated in a unit test, so
/// the shared decision was lifted into a static helper — same testability pattern
/// as `AppState.shouldAnonReRegister` / `nextLeafForCountry`. This is the revenue
/// path's premium gate; a wrong answer either locks out a payer or grants premium
/// to an expired/revoked transaction.
@MainActor
final class SubscriptionEntitlementTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var known: String { SubscriptionManager.product30 }

    func testActiveSubscriptionWithFutureExpiry() {
        XCTAssertTrue(SubscriptionManager.isActiveEntitlement(
            productID: known, revocationDate: nil,
            expirationDate: now.addingTimeInterval(86_400), now: now))
    }

    func testExpiredSubscriptionIsInactive() {
        XCTAssertFalse(SubscriptionManager.isActiveEntitlement(
            productID: known, revocationDate: nil,
            expirationDate: now.addingTimeInterval(-1), now: now))
    }

    func testExpiryExactlyNowIsInactive() {
        // expiry <= now → inactive (preserves the original `expiry <= Date()` guard).
        XCTAssertFalse(SubscriptionManager.isActiveEntitlement(
            productID: known, revocationDate: nil,
            expirationDate: now, now: now))
    }

    func testNoExpiryIsActiveWhileUnrevoked() {
        // Lifetime / non-subscription entitlement: nil expiry → active.
        XCTAssertTrue(SubscriptionManager.isActiveEntitlement(
            productID: known, revocationDate: nil,
            expirationDate: nil, now: now))
    }

    func testRevokedIsInactiveEvenWithFutureExpiry() {
        XCTAssertFalse(SubscriptionManager.isActiveEntitlement(
            productID: known,
            revocationDate: now.addingTimeInterval(-3600),
            expirationDate: now.addingTimeInterval(86_400), now: now))
    }

    func testUnknownProductIsInactive() {
        XCTAssertFalse(SubscriptionManager.isActiveEntitlement(
            productID: "com.madfrog.vpn.sub.999days", revocationDate: nil,
            expirationDate: now.addingTimeInterval(86_400), now: now))
    }

    func testAllKnownProductIDsAreAccepted() {
        XCTAssertEqual(SubscriptionManager.allProductIDs.count, 4)
        for id in SubscriptionManager.allProductIDs {
            XCTAssertTrue(SubscriptionManager.isActiveEntitlement(
                productID: id, revocationDate: nil, expirationDate: nil, now: now),
                "expected known product \(id) to be accepted")
        }
    }
}
