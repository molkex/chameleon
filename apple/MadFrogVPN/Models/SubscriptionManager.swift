import StoreKit
import Foundation

/// Manages App Store subscriptions via StoreKit 2.
/// Runs on @MainActor so that published properties can drive SwiftUI views directly.
@MainActor
@Observable
class SubscriptionManager {

    // MARK: - Product IDs

    static let monthlyID = AppConfig.monthlyProductID
    static let yearlyID  = AppConfig.yearlyProductID

    // MARK: - Published State

    /// Products fetched from App Store, sorted monthly → yearly.
    var products: [Product] = []

    /// True while loadProducts() or purchase() is in flight.
    var isLoading = false

    /// Human-readable error to surface in the UI.
    var purchaseError: String?

    /// True when the user holds an active subscription or an active
    /// Telegram-bot activation (set externally by AppState).
    var isPremium = false

    // MARK: - Private

    // nonisolated(unsafe) allows deinit (non-isolated) to cancel the task
    nonisolated(unsafe) private var transactionListenerTask: Task<Void, Never>?

    init() {
        // Start listening for StoreKit transactions immediately.
        transactionListenerTask = Task { [weak self] in
            await self?.listenForTransactions()
        }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Load Products

    /// Fetch the two subscription products from App Store Connect.
    func loadProducts() async {
        isLoading = true
        purchaseError = nil
        defer { isLoading = false }

        do {
            let fetched = try await Product.products(
                for: [Self.monthlyID, Self.yearlyID]
            )
            // Sort so monthly appears first in the paywall.
            products = fetched.sorted { lhs, rhs in
                let order: [String] = [Self.monthlyID, Self.yearlyID]
                let li = order.firstIndex(of: lhs.id) ?? Int.max
                let ri = order.firstIndex(of: rhs.id) ?? Int.max
                return li < ri
            }
            AppLogger.app.info("SubscriptionManager: loaded \(fetched.count) products")
        } catch {
            purchaseError = "Не удалось загрузить продукты: \(error.localizedDescription)"
            AppLogger.app.error("SubscriptionManager loadProducts: \(error)")
        }
    }

    // MARK: - Purchase

    /// Initiate a purchase flow for the given product.
    /// Returns true on successful purchase, false if cancelled.
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
                await updatePremiumStatus()
                await transaction.finish()
                // TODO: sync purchase receipt to backend for server-side verification
                // await syncPurchaseToBackend(transaction: transaction)
                AppLogger.app.info("SubscriptionManager: purchase success \(product.id)")
                return true

            case .userCancelled:
                AppLogger.app.info("SubscriptionManager: user cancelled purchase")
                return false

            case .pending:
                purchaseError = "Покупка ожидает подтверждения (Family Sharing или Ask to Buy)"
                return false

            @unknown default:
                return false
            }
        } catch {
            purchaseError = "Ошибка покупки: \(error.localizedDescription)"
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
            // AppStore.sync() re-syncs receipts from the server.
            try await AppStore.sync()
            await updatePremiumStatus()
            AppLogger.app.info("SubscriptionManager: restore completed, isPremium=\(self.isPremium)")
        } catch {
            purchaseError = "Не удалось восстановить покупки: \(error.localizedDescription)"
            AppLogger.app.error("SubscriptionManager restorePurchases: \(error)")
        }
    }

    // MARK: - Check Subscription Status

    /// Verify current entitlements and update isPremium.
    /// Call this on app launch and after any purchase/restore.
    func checkSubscriptionStatus() async {
        await updatePremiumStatus()
    }

    // MARK: - Transaction Listener

    /// Long-lived Task that handles transactions delivered outside of the app's
    /// normal purchase flow (e.g. subscription renewals, refunds).
    private func listenForTransactions() async {
        for await result in Transaction.updates {
            do {
                let transaction = try checkVerified(result)
                await updatePremiumStatus()
                await transaction.finish()
                AppLogger.app.info("SubscriptionManager: transaction update finished \(transaction.productID)")
            } catch {
                AppLogger.app.error("SubscriptionManager listenForTransactions: \(error)")
            }
        }
    }

    // MARK: - Internal Helpers

    /// Walk current entitlements and set isPremium accordingly.
    private func updatePremiumStatus() async {
        var hasActive = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            // Only our own product IDs count.
            let ours = [Self.monthlyID, Self.yearlyID]
            guard ours.contains(transaction.productID) else { continue }
            // Subscription must not be revoked and must cover today.
            if transaction.revocationDate == nil {
                if let expiry = transaction.expirationDate {
                    if expiry > Date() { hasActive = true }
                } else {
                    // Non-consumable / lifetime (not expected here, but be safe)
                    hasActive = true
                }
            }
        }
        isPremium = hasActive
        AppLogger.app.debug("SubscriptionManager: isPremium=\(hasActive)")
    }

    /// Unwrap a VerificationResult and throw if unverified.
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }

    // MARK: - Convenience

    /// Returns the monthly product if loaded.
    var monthlyProduct: Product? {
        products.first(where: { $0.id == Self.monthlyID })
    }

    /// Returns the yearly product if loaded.
    var yearlyProduct: Product? {
        products.first(where: { $0.id == Self.yearlyID })
    }

    /// Percentage saving of the yearly plan vs 12 × monthly price (0 if unavailable).
    var yearlySavingsPercent: Int {
        guard let monthly = monthlyProduct,
              let yearly = yearlyProduct,
              monthly.price > 0
        else { return 0 }
        let annualCostIfMonthly = monthly.price * 12
        let saving = (annualCostIfMonthly - yearly.price) / annualCostIfMonthly
        return Int(NSDecimalNumber(decimal: saving * 100).doubleValue.rounded())
    }
}
