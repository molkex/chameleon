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
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Paywall.close) { dismiss() }
                }
            }
            .task {
                if sub.products.isEmpty { await sub.loadProducts() }
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
            }
            .sheet(isPresented: $showPrivacy) {
                NavigationStack {
                    LegalView(title: L10n.Legal.privacyTitle, body: L10n.Legal.privacyBody)
                }
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
                .onTapGesture { selectedProductID = product.id }
            }
        }
    }

    private var purchaseButton: some View {
        Button {
            guard let product = sub.product(for: selectedProductID) else { return }
            Task {
                let ok = await sub.purchase(product)
                if ok { dismiss() }
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
