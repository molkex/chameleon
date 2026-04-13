import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProductID: String = SubscriptionManager.product90
    @State private var showRestoredAlert = false

    private var sub: SubscriptionManager { app.subscriptionManager }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header

                    if sub.isLoading && sub.products.isEmpty {
                        ProgressView().padding(.top, 40)
                    } else if sub.products.isEmpty {
                        VStack(spacing: 12) {
                            Text("Тарифы недоступны")
                                .font(.headline)
                            Text("Проверьте подключение и попробуйте ещё раз.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Повторить") { Task { await sub.loadProducts() } }
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
                            if sub.isPremium { showRestoredAlert = true }
                        }
                    } label: {
                        Text("Восстановить покупки")
                            .font(.footnote)
                    }
                    .disabled(sub.isLoading)

                    legalFooter
                }
                .padding()
            }
            .navigationTitle("Premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .task {
                if sub.products.isEmpty { await sub.loadProducts() }
            }
            .onChange(of: sub.isPremium) { _, newValue in
                if newValue { dismiss() }
            }
            .alert("Покупки восстановлены", isPresented: $showRestoredAlert) {
                Button("OK") { dismiss() }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Безлимитный доступ")
                .font(.title2.bold())
            Text("Быстрые серверы, без рекламы, без лимитов.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var planCards: some View {
        VStack(spacing: 12) {
            ForEach(sub.products, id: \.id) { product in
                PlanCard(
                    product: product,
                    isSelected: product.id == selectedProductID
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
                if sub.isLoading { ProgressView().tint(.white) }
                Text("Оформить подписку")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(sub.isLoading || sub.products.isEmpty)
    }

    private var legalFooter: some View {
        VStack(spacing: 4) {
            Text("Оплата будет списана с вашего Apple ID. Подписка не продлевается автоматически — это разовая покупка на выбранный срок.")
            HStack(spacing: 12) {
                Link("Условия", destination: URL(string: "https://madfrog.vpn/terms")!)
                Link("Конфиденциальность", destination: URL(string: "https://madfrog.vpn/privacy")!)
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

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(product.displayName)
                    .font(.headline)
                Text(product.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(product.displayPrice)
                .font(.title3.bold())
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }
}
