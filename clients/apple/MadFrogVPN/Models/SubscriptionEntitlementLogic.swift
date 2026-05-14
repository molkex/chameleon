import Foundation

/// Pure entitlement / product-catalog logic extracted from
/// `SubscriptionManager` so the branchy parts are unit-testable without
/// faking StoreKit's `Product` / `Transaction` / `VerificationResult`
/// types (which have no public initialisers).
///
/// Behaviour-preserving: each function mirrors an inline expression that
/// previously lived in `SubscriptionManager`. The live StoreKit calls
/// (`Product.products`, `product.purchase()`, `Transaction.updates`,
/// `Transaction.currentEntitlements`) stay in `SubscriptionManager` and
/// remain on-device-verified.
enum SubscriptionEntitlementLogic {

    // MARK: - Catalog ordering

    /// Sort-rank of a product id within the canonical 30 → 365 ordering.
    /// Ids not in `order` sink to the bottom (`.max`) — mirrors the
    /// `order.firstIndex(of:) ?? .max` used by `loadProducts()`.
    static func sortRank(productID: String, order: [String]) -> Int {
        order.firstIndex(of: productID) ?? .max
    }

    /// Order two product ids by their position in `order` (lower rank
    /// first). Lifted verbatim from `loadProducts()`'s `sorted` closure so
    /// the catalog ordering can be tested against plain id strings.
    static func productIsOrderedBefore(_ lhs: String, _ rhs: String, order: [String]) -> Bool {
        sortRank(productID: lhs, order: order) < sortRank(productID: rhs, order: order)
    }

    /// The set of expected product ids that the App Store did NOT return —
    /// drives the `loadProducts()` "missing products" warning.
    static func missingProductIDs(expected: [String], fetched: [String]) -> Set<String> {
        Set(expected).subtracting(fetched)
    }

    /// Whether the App Store returned the full catalog.
    static func didLoadFullCatalog(expectedCount: Int, fetchedCount: Int) -> Bool {
        fetchedCount >= expectedCount
    }

    // MARK: - Product membership

    /// Whether a transaction's `productID` is one of ours. Both
    /// `syncTransactionToBackend` and `updatePremiumStatus` gate on this so
    /// a Family-Sharing delivery of an unrelated app's product is ignored.
    static func isOwnProduct(_ productID: String, ownProductIDs: [String]) -> Bool {
        ownProductIDs.contains(productID)
    }

    // MARK: - Entitlement evaluation

    /// Whether a single verified entitlement counts as an active premium
    /// grant. Mirrors the inner test in `updatePremiumStatus()`:
    ///   - a non-nil `revocationDate` (refunded / chargeback) → not active,
    ///   - a non-nil `expirationDate` is active only while it's in the
    ///     future,
    ///   - a nil `expirationDate` (non-consumable / lifetime) → active.
    ///
    /// `now` is injected so the boundary is deterministic in tests.
    static func entitlementIsActive(
        revocationDate: Date?,
        expirationDate: Date?,
        now: Date
    ) -> Bool {
        if revocationDate != nil { return false }
        guard let expiry = expirationDate else { return true }
        return expiry > now
    }

    /// Roll up a set of verified entitlements into the `isPremium` flag:
    /// the user is premium iff *any* owned, unrevoked, unexpired
    /// entitlement exists. Mirrors the `hasActive` accumulation loop in
    /// `updatePremiumStatus()`.
    ///
    /// Each tuple is `(productID, revocationDate, expirationDate)` —
    /// exactly the three fields the loop reads off a `Transaction`.
    static func isPremium(
        entitlements: [(productID: String, revocationDate: Date?, expirationDate: Date?)],
        ownProductIDs: [String],
        now: Date
    ) -> Bool {
        entitlements.contains { e in
            isOwnProduct(e.productID, ownProductIDs: ownProductIDs)
                && entitlementIsActive(
                    revocationDate: e.revocationDate,
                    expirationDate: e.expirationDate,
                    now: now
                )
        }
    }
}
