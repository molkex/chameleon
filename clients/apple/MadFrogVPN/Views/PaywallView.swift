import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(AppState.self) private var app
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProductID: String = SubscriptionManager.product90
    @State private var showRestoredAlert = false
    @State private var showTerms = false
    @State private var showPrivacy = false

    private var sub: SubscriptionManager { app.subscriptionManager }
    private var theme: Theme { themeManager.current }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header

                    PaywallBenefits(theme: theme)   // B1: value pitch above the plans

                    if sub.isLoading && sub.products.isEmpty {
                        ProgressView().padding(.top, 40)
                    } else if sub.products.isEmpty {
                        VStack(spacing: 12) {
                            Text(L10n.Paywall.noProductsTitle)
                                .font(.headline)
                            Text(L10n.Paywall.noProductsHint)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button(L10n.Paywall.retry) { Task { await sub.loadProducts() } }
                                .buttonStyle(.bordered)
                        }
                        .padding(.top, 40)
                    } else {
                        planCards
                    }

                    if let error = sub.purchaseError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    purchaseButton

                    Button {
                        Task {
                            await sub.restorePurchases()
                            if sub.isPremium {
                                await app.refreshAfterPurchase()
                                showRestoredAlert = true
                            }
                        }
                    } label: {
                        Text(L10n.Paywall.restore)
                            .font(.footnote)
                    }
                    .disabled(sub.isLoading)

                    legalFooter
                }
                .padding()
            }
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(Text(L10n.Paywall.title))
            .iosInlineNavTitle()
            .iosToolbarBackground(theme.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Paywall.close) { dismiss() }
                }
            }
            .task {
                if sub.products.isEmpty { await sub.loadProducts() }
                // USR-09 Phase 2 — paywall impression. Logged after
                // products load so the property bag can carry the count
                // (zero is a real signal: storefront failure or empty
                // app store config).
                await app.eventTracker.log(
                    name: "paywall.view",
                    properties: [
                        "products": sub.products.count,
                        "storefront": "storekit",
                    ]
                )
            }
            .onChange(of: sub.isPremium) { _, newValue in
                if newValue {
                    Task {
                        await app.refreshAfterPurchase()
                        dismiss()
                    }
                }
            }
            .alert(Text(L10n.Paywall.restoredAlert), isPresented: $showRestoredAlert) {
                Button(L10n.Paywall.ok) { dismiss() }
            }
            .sheet(isPresented: $showTerms) {
                NavigationStack {
                    LegalView(title: L10n.Legal.termsTitle, body: L10n.Legal.termsBody)
                }
                .macSheetSize()
            }
            .sheet(isPresented: $showPrivacy) {
                NavigationStack {
                    LegalView(title: L10n.Legal.privacyTitle, body: L10n.Legal.privacyBody)
                }
                .macSheetSize()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 48))
                .foregroundStyle(theme.accent)
            Text(L10n.Paywall.headerTitle)
                .font(theme.displayFont(size: 24, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            Text(L10n.Paywall.headerSubtitle)
                .font(theme.font(size: 14))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var planCards: some View {
        VStack(spacing: 12) {
            ForEach(sub.products, id: \.id) { product in
                PlanCard(
                    product: product,
                    isSelected: product.id == selectedProductID,
                    theme: theme
                )
                .onTapGesture {
                    selectedProductID = product.id
                    // USR-09 Phase 2 — product tap. The funnel needs to
                    // know which product the user reached for before
                    // pressing the buy button, especially when the buy
                    // button click never happens.
                    Task {
                        await app.eventTracker.log(
                            name: "paywall.product.tap",
                            properties: [
                                "product_id": product.id,
                                "price": "\(product.price)",
                            ]
                        )
                    }
                }
            }
        }
    }

    private var purchaseButton: some View {
        Button {
            guard let product = sub.product(for: selectedProductID) else { return }
            Task {
                // USR-09 Phase 2 — purchase intent.
                await app.eventTracker.log(
                    name: "purchase.start",
                    properties: ["product_id": product.id]
                )
                let ok = await sub.purchase(product)
                // Outcome event. `ok == false` may mean cancel,
                // pending (Ask to Buy), or fail with an error; we
                // disambiguate via `purchaseError`.
                if ok {
                    await app.eventTracker.log(
                        name: "purchase.success",
                        properties: ["product_id": product.id]
                    )
                    dismiss()
                } else if let err = sub.purchaseError, !err.isEmpty {
                    await app.eventTracker.log(
                        name: "purchase.fail",
                        properties: ["product_id": product.id, "reason": err]
                    )
                } else {
                    // No error → user cancelled or Ask-to-Buy pending.
                    await app.eventTracker.log(
                        name: "purchase.cancel",
                        properties: ["product_id": product.id]
                    )
                }
            }
        } label: {
            HStack {
                if sub.isLoading { ProgressView().tint(theme.background) }
                Text(L10n.Paywall.purchase)
                    .font(theme.font(size: 17, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(theme.accent)
            .foregroundStyle(theme.background)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
        .disabled(sub.isLoading || sub.products.isEmpty)
    }

    private var legalFooter: some View {
        VStack(spacing: 4) {
            Text(L10n.Paywall.legal)
            HStack(spacing: 12) {
                Button { showTerms = true } label: { Text(L10n.Paywall.terms) }
                Button { showPrivacy = true } label: { Text(L10n.Paywall.privacy) }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, 8)
    }
}

private struct PlanCard: View {
    let product: Product
    let isSelected: Bool
    let theme: Theme

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(product.displayName)
                    .font(theme.font(size: 17, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(product.description)
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Text(product.displayPrice)
                .font(theme.displayFont(size: 20, weight: .bold))
                .foregroundStyle(theme.accent)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: theme.cardCornerRadius)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.cardCornerRadius)
                .strokeBorder(isSelected ? theme.accent : Color.clear, lineWidth: 2)
        )
    }
}
