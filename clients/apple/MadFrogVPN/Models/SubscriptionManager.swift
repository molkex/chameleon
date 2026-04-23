import Foundation
import StoreKit

/// Manages App Store subscriptions via StoreKit 2.
///
/// Flow for a new purchase:
///   1. `loadProducts()` fetches the four tier products from App Store.
///   2. `purchase(_:)` opens StoreKit's native purchase sheet.
///   3. On success, the verified JWS string from StoreKit is POSTed to the
///      backend via `APIClient.verifySubscription`. The backend validates the
///      JWS chain against Apple's root CA, extends `subscription_expiry`, and
///      records the payment idempotently. Only after that do we `finish()`
///      the transaction — so a crash between purchase and sync makes StoreKit
///      re-deliver the transaction on next launch via `Transaction.updates`.
///
/// Transaction.updates handles renewals, refunds, and crash recovery: every
/// delivery re-syncs to the backend before `finish()`.
@MainActor
@Observable
final class SubscriptionManager {

    // MARK: - Product IDs

    /// Keep these in sync with `backend/internal/api/mobile/subscription.go productDays`
    /// and with the product IDs created in App Store Connect.
    static let product30  = "com.madfrog.vpn.sub.30days"
    static let product90  = "com.madfrog.vpn.sub.90days"
    static let product180 = "com.madfrog.vpn.sub.180days"
    static let product365 = "com.madfrog.vpn.sub.365days"

    static let allProductIDs: [String] = [product30, product90, product180, product365]

    // MARK: - Published State

    /// Products fetched from App Store, sorted by duration (30 → 365).
    var products: [Product] = []

    /// True while `loadProducts()` / `purchase()` / `restorePurchases()` is in flight.
    var isLoading = false

    /// Human-readable error to surface in the UI. Cleared by the caller.
    var purchaseError: String?

    /// True when the user holds a verified, unrevoked, unexpired entitlement
    /// to any of our products. Updated after every transaction delivery.
    var isPremium = false

    /// Expiry from the most recent backend verification response (unix seconds).
    /// Used so the UI can show "active until …" without re-hitting StoreKit.
    var backendExpiryUnix: Int64 = 0

    // MARK: - Private

    /// Injected at construction time so the manager can push verified JWS to
    /// the server. Using a closure instead of holding APIClient directly keeps
    /// the manager testable and avoids a hard dependency on AppState.
    private let syncToBackend: (_ signedJWS: String) async throws -> APIClient.SubscriptionVerification

    nonisolated(unsafe) private var transactionListenerTask: Task<Void, Never>?

    init(syncToBackend: @escaping (_ signedJWS: String) async throws -> APIClient.SubscriptionVerification) {
        self.syncToBackend = syncToBackend
        transactionListenerTask = Task { [weak self] in
            await self?.listenForTransactions()
        }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Load Products

    func loadProducts() async {
        isLoading = true
        purchaseError = nil
        defer { isLoading = false }

        do {
            let fetched = try await Product.products(for: Self.allProductIDs)
            let order = Self.allProductIDs
            products = fetched.sorted { lhs, rhs in
                (order.firstIndex(of: lhs.id) ?? .max) < (order.firstIndex(of: rhs.id) ?? .max)
            }
            AppLogger.app.info("SubscriptionManager: loaded \(fetched.count)/\(Self.allProductIDs.count) products")
            if fetched.count < Self.allProductIDs.count {
                let missing = Set(Self.allProductIDs).subtracting(fetched.map(\.id))
                AppLogger.app.warning("SubscriptionManager: missing products \(missing.joined(separator: ", "))")
            }
        } catch {
            purchaseError = String(format: "subscription.error.load_failed".localized, error.localizedDescription)
            AppLogger.app.error("SubscriptionManager loadProducts: \(error)")
        }
    }

    // MARK: - Purchase

    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        isLoading = true
        purchaseError = nil
        defer { isLoading = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                // Push to backend BEFORE finishing. If the network fails, the
                // transaction stays unfinished and StoreKit re-delivers it on
                // the next launch via Transaction.updates.
                try await syncTransactionToBackend(transaction, jws: verification.jwsRepresentation)
                await transaction.finish()
                await updatePremiumStatus()
                AppLogger.app.info("SubscriptionManager: purchase success \(product.id)")
                return true

            case .userCancelled:
                AppLogger.app.info("SubscriptionManager: user cancelled purchase")
                return false

            case .pending:
                purchaseError = "subscription.error.ask_to_buy".localized
                return false

            @unknown default:
                return false
            }
        } catch {
            purchaseError = String(format: "subscription.error.purchase_failed".localized, error.localizedDescription)
            AppLogger.app.error("SubscriptionManager purchase: \(error)")
            return false
        }
    }

    // MARK: - Restore Purchases

    func restorePurchases() async {
        isLoading = true
        purchaseError = nil
        defer { isLoading = false }

        do {
            try await AppStore.sync()
            // After sync, walk current entitlements and push any verified ones to the backend.
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result,
                      Self.allProductIDs.contains(transaction.productID) else { continue }
                let jws = result.jwsRepresentation
                try? await syncTransactionToBackend(transaction, jws: jws)
            }
            await updatePremiumStatus()
            AppLogger.app.info("SubscriptionManager: restore completed, isPremium=\(self.isPremium)")
        } catch {
            purchaseError = String(format: "subscription.error.restore_failed".localized, error.localizedDescription)
            AppLogger.app.error("SubscriptionManager restorePurchases: \(error)")
        }
    }

    /// Walk current entitlements on app launch and update `isPremium`.
    /// Does NOT re-sync to backend — that would be wasteful on every launch.
    /// Use `restorePurchases()` for explicit server re-sync.
    func checkSubscriptionStatus() async {
        await updatePremiumStatus()
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            do {
                let transaction = try checkVerified(result)
                // This path catches: auto-renewals, refunds, purchases made on
                // another device, and purchases whose initial sync was interrupted.
                try await syncTransactionToBackend(transaction, jws: result.jwsRepresentation)
                await transaction.finish()
                await updatePremiumStatus()
                AppLogger.app.info("SubscriptionManager: transaction update handled \(transaction.productID)")
            } catch {
                AppLogger.app.error("SubscriptionManager listenForTransactions: \(error)")
            }
        }
    }

    // MARK: - Internal Helpers

    private func syncTransactionToBackend(_ transaction: Transaction, jws: String) async throws {
        guard Self.allProductIDs.contains(transaction.productID) else { return }
        let verified = try await syncToBackend(jws)
        backendExpiryUnix = verified.subscriptionExpiry
        AppLogger.app.info("SubscriptionManager: backend verified \(verified.productId) expiry=\(verified.subscriptionExpiry) already=\(verified.alreadyApplied)")
    }

    private func updatePremiumStatus() async {
        var hasActive = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.allProductIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            if let expiry = transaction.expirationDate {
                if expiry > Date() { hasActive = true }
            } else {
                hasActive = true
            }
        }
        isPremium = hasActive
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }

    // MARK: - Convenience

    func product(for id: String) -> Product? {
        products.first { $0.id == id }
    }
}
