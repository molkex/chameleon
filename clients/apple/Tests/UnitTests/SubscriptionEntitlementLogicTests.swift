import XCTest
@testable import MadFrogVPN

/// test-coverage (ios-subscription-manager): pins the pure entitlement /
/// catalog logic extracted from `SubscriptionManager`. StoreKit's
/// `Product` / `Transaction` / `VerificationResult` have no public
/// initialisers, so the live calls stay on-device-verified — what's
/// tested here is the deterministic logic those calls feed into:
/// catalog ordering, own-product gating, and "is this entitlement
/// active right now" evaluation.
final class SubscriptionEntitlementLogicTests: XCTestCase {

    private let order = [
        SubscriptionManager.product30,
        SubscriptionManager.product90,
        SubscriptionManager.product180,
        SubscriptionManager.product365,
    ]

    // MARK: - Catalog ordering

    func testSortRank_followsCanonicalOrder() {
        XCTAssertEqual(SubscriptionEntitlementLogic.sortRank(productID: SubscriptionManager.product30, order: order), 0)
        XCTAssertEqual(SubscriptionEntitlementLogic.sortRank(productID: SubscriptionManager.product365, order: order), 3)
    }

    func testSortRank_unknownProductSinksToBottom() {
        XCTAssertEqual(SubscriptionEntitlementLogic.sortRank(productID: "com.madfrog.vpn.sub.unknown", order: order), .max)
    }

    func testProductIsOrderedBefore_30Before365() {
        XCTAssertTrue(SubscriptionEntitlementLogic.productIsOrderedBefore(
            SubscriptionManager.product30, SubscriptionManager.product365, order: order))
        XCTAssertFalse(SubscriptionEntitlementLogic.productIsOrderedBefore(
            SubscriptionManager.product365, SubscriptionManager.product30, order: order))
    }

    func testProductIsOrderedBefore_sortsAScrambledCatalog() {
        let scrambled = [
            SubscriptionManager.product365,
            SubscriptionManager.product30,
            SubscriptionManager.product180,
            SubscriptionManager.product90,
        ]
        let sorted = scrambled.sorted { SubscriptionEntitlementLogic.productIsOrderedBefore($0, $1, order: order) }
        XCTAssertEqual(sorted, order, "the catalog must always render 30 → 365")
    }

    func testMissingProductIDs() {
        let fetched = [SubscriptionManager.product30, SubscriptionManager.product90]
        let missing = SubscriptionEntitlementLogic.missingProductIDs(expected: order, fetched: fetched)
        XCTAssertEqual(missing, [SubscriptionManager.product180, SubscriptionManager.product365])
    }

    func testMissingProductIDs_noneMissing() {
        XCTAssertTrue(SubscriptionEntitlementLogic.missingProductIDs(expected: order, fetched: order).isEmpty)
    }

    func testDidLoadFullCatalog() {
        XCTAssertTrue(SubscriptionEntitlementLogic.didLoadFullCatalog(expectedCount: 4, fetchedCount: 4))
        XCTAssertFalse(SubscriptionEntitlementLogic.didLoadFullCatalog(expectedCount: 4, fetchedCount: 3))
        // Defensive: more than expected still counts as "full".
        XCTAssertTrue(SubscriptionEntitlementLogic.didLoadFullCatalog(expectedCount: 4, fetchedCount: 5))
    }

    // MARK: - Own-product membership

    func testIsOwnProduct() {
        XCTAssertTrue(SubscriptionEntitlementLogic.isOwnProduct(SubscriptionManager.product90, ownProductIDs: order))
        XCTAssertFalse(SubscriptionEntitlementLogic.isOwnProduct("com.someoneelse.app.sub", ownProductIDs: order),
                       "a Family-Sharing delivery of an unrelated product must be ignored")
    }

    // MARK: - entitlementIsActive

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testEntitlementIsActive_futureExpiryIsActive() {
        XCTAssertTrue(SubscriptionEntitlementLogic.entitlementIsActive(
            revocationDate: nil,
            expirationDate: now.addingTimeInterval(86_400),
            now: now))
    }

    func testEntitlementIsActive_pastExpiryIsInactive() {
        XCTAssertFalse(SubscriptionEntitlementLogic.entitlementIsActive(
            revocationDate: nil,
            expirationDate: now.addingTimeInterval(-1),
            now: now))
    }

    func testEntitlementIsActive_expiryExactlyNowIsInactive() {
        // strictly `expiry > now` — the boundary instant is already expired.
        XCTAssertFalse(SubscriptionEntitlementLogic.entitlementIsActive(
            revocationDate: nil,
            expirationDate: now,
            now: now))
    }

    func testEntitlementIsActive_nilExpiryIsActive() {
        // Non-consumable / lifetime grant — no expiry means always active.
        XCTAssertTrue(SubscriptionEntitlementLogic.entitlementIsActive(
            revocationDate: nil,
            expirationDate: nil,
            now: now))
    }

    func testEntitlementIsActive_revokedIsInactiveEvenIfUnexpired() {
        // Refund / chargeback wins over a still-future expiry.
        XCTAssertFalse(SubscriptionEntitlementLogic.entitlementIsActive(
            revocationDate: now.addingTimeInterval(-100),
            expirationDate: now.addingTimeInterval(86_400),
            now: now))
    }

    func testEntitlementIsActive_revokedLifetimeIsInactive() {
        XCTAssertFalse(SubscriptionEntitlementLogic.entitlementIsActive(
            revocationDate: now,
            expirationDate: nil,
            now: now))
    }

    // MARK: - isPremium roll-up

    func testIsPremium_trueWhenAnyOwnedActiveEntitlement() {
        let entitlements: [(productID: String, revocationDate: Date?, expirationDate: Date?)] = [
            (SubscriptionManager.product30, nil, now.addingTimeInterval(-1)),   // expired
            (SubscriptionManager.product90, nil, now.addingTimeInterval(86_400)), // active
        ]
        XCTAssertTrue(SubscriptionEntitlementLogic.isPremium(entitlements: entitlements, ownProductIDs: order, now: now))
    }

    func testIsPremium_falseWhenAllExpiredOrRevoked() {
        let entitlements: [(productID: String, revocationDate: Date?, expirationDate: Date?)] = [
            (SubscriptionManager.product30, nil, now.addingTimeInterval(-1)),
            (SubscriptionManager.product90, now, now.addingTimeInterval(86_400)),
        ]
        XCTAssertFalse(SubscriptionEntitlementLogic.isPremium(entitlements: entitlements, ownProductIDs: order, now: now))
    }

    func testIsPremium_ignoresForeignActiveProduct() {
        // An active entitlement for a product that isn't ours must not
        // grant premium.
        let entitlements: [(productID: String, revocationDate: Date?, expirationDate: Date?)] = [
            ("com.someoneelse.app.sub", nil, now.addingTimeInterval(86_400)),
        ]
        XCTAssertFalse(SubscriptionEntitlementLogic.isPremium(entitlements: entitlements, ownProductIDs: order, now: now))
    }

    func testIsPremium_emptyEntitlementsIsFalse() {
        XCTAssertFalse(SubscriptionEntitlementLogic.isPremium(entitlements: [], ownProductIDs: order, now: now))
    }

    func testIsPremium_lifetimeOwnedGrantsPremium() {
        let entitlements: [(productID: String, revocationDate: Date?, expirationDate: Date?)] = [
            (SubscriptionManager.product365, nil, nil),
        ]
        XCTAssertTrue(SubscriptionEntitlementLogic.isPremium(entitlements: entitlements, ownProductIDs: order, now: now))
    }
}
