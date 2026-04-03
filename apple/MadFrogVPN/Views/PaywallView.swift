import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Pre-select yearly to highlight the best value option.
    @State private var selectedProductID: String = SubscriptionManager.yearlyID

    private var subscriptionManager: SubscriptionManager { appState.subscriptionManager }

    private let accentGreen = Color(red: 0.2, green: 0.84, blue: 0.42)

    // MARK: - Body

    var body: some View {
        ZStack {
            // Dark background matching the rest of the app
            Color(red: 0.06, green: 0.07, blue: 0.09)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    closeButton
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                    heroSection
                        .padding(.top, 8)

                    benefitsSection
                        .padding(.top, 28)

                    if subscriptionManager.isLoading && subscriptionManager.products.isEmpty {
                        productsLoadingState
                            .padding(.top, 32)
                    } else if subscriptionManager.products.isEmpty {
                        productsUnavailableState
                            .padding(.top, 32)
                    } else {
                        plansSection
                            .padding(.top, 28)
                        ctaButton
                            .padding(.top, 20)
                    }

                    if let errorMessage = subscriptionManager.purchaseError {
                        errorBanner(errorMessage)
                            .padding(.top, 16)
                    }

                    restoreButton
                        .padding(.top, 16)

                    legalFooter
                        .padding(.top, 12)
                        .padding(.bottom, 32)
                }
                .padding(.horizontal, 20)
            }
        }
        .task {
            await subscriptionManager.loadProducts()
        }
        .onChange(of: subscriptionManager.isPremium) { _, newValue in
            if newValue { dismiss() }
        }
    }

    // MARK: - Close Button

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accentGreen.opacity(0.25), accentGreen.opacity(0.0)],
                            center: .center,
                            startRadius: 30,
                            endRadius: 80
                        )
                    )
                    .frame(width: 160, height: 160)

                Image(systemName: "shield.fill")
                    .font(.system(size: 68, weight: .semibold))
                    .foregroundStyle(accentGreen)
                    .symbolEffect(.pulse)
            }

            Text(AppConfig.appName)
                .font(.title.weight(.bold))
                .foregroundStyle(.white)

            Text("Безопасный и быстрый VPN\nдля обхода блокировок в России")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
    }

    // MARK: - Benefits

    private var benefitsSection: some View {
        VStack(spacing: 10) {
            benefitRow(icon: "lock.shield.fill",
                       color: accentGreen,
                       title: "Безопасный VPN",
                       subtitle: "VLESS Reality + Hysteria2, без логов")
            benefitRow(icon: "globe.europe.africa.fill",
                       color: Color(red: 0.3, green: 0.6, blue: 1.0),
                       title: "2 сервера NL + DE",
                       subtitle: "Нидерланды и Германия, автовыбор по пингу")
            benefitRow(icon: "iphone.and.arrow.forward",
                       color: Color(red: 1.0, green: 0.7, blue: 0.2),
                       title: "Все устройства",
                       subtitle: "iOS, macOS, Android, Windows")
            benefitRow(icon: "bolt.fill",
                       color: Color(red: 0.8, green: 0.3, blue: 1.0),
                       title: "Быстрые протоколы",
                       subtitle: "Smart-выбор лучшего протокола автоматически")
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func benefitRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Plans

    private var plansSection: some View {
        VStack(spacing: 10) {
            ForEach(subscriptionManager.products) { product in
                planCard(product: product)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedProductID = product.id
                        }
                    }
            }
        }
    }

    private func planCard(product: Product) -> some View {
        let isSelected = selectedProductID == product.id
        let isYearly = product.id == SubscriptionManager.yearlyID
        let savings = subscriptionManager.yearlySavingsPercent

        return ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                // Selection indicator
                ZStack {
                    Circle()
                        .stroke(isSelected ? accentGreen : Color.white.opacity(0.2),
                                lineWidth: 2)
                        .frame(width: 22, height: 22)
                    if isSelected {
                        Circle()
                            .fill(accentGreen)
                            .frame(width: 13, height: 13)
                    }
                }
                .padding(.trailing, 14)

                VStack(alignment: .leading, spacing: 3) {
                    Text(isYearly ? "Год" : "Месяц")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    if isYearly {
                        Text("Лучшая цена")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(accentGreen)
                    } else {
                        Text("Ежемесячная оплата")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(product.displayPrice)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                    if isYearly {
                        let monthlyEquiv = product.price / 12
                        Text("\(formattedPrice(monthlyEquiv, currencyCode: product.priceFormatStyle.currencyCode)) / мес.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("/ месяц")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected
                          ? accentGreen.opacity(0.12)
                          : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isSelected ? accentGreen.opacity(0.6) : Color.white.opacity(0.1),
                                lineWidth: isSelected ? 1.5 : 0.5
                            )
                    )
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)

            // Savings badge on yearly plan
            if isYearly && savings > 0 {
                Text("−\(savings)%")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(accentGreen)
                    )
                    .offset(x: -10, y: -10)
            }
        }
    }

    // MARK: - CTA Button

    private var ctaButton: some View {
        Button {
            Task { await purchaseSelected() }
        } label: {
            ZStack {
                if subscriptionManager.isLoading {
                    ProgressView()
                        .tint(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.subheadline.weight(.semibold))
                        Text(ctaTitle)
                            .font(.headline.weight(.bold))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(accentGreen)
                    .shadow(color: accentGreen.opacity(0.45), radius: 12, y: 4)
            )
        }
        .buttonStyle(.plain)
        .disabled(subscriptionManager.isLoading)
    }

    private var ctaTitle: String {
        // If the selected product has a free trial, say so
        if let product = subscriptionManager.products.first(where: { $0.id == selectedProductID }),
           let offer = product.subscription?.introductoryOffer,
           offer.paymentMode == .freeTrial {
            let days = Int(offer.period.value)
            return "Попробовать \(days) \(daysString(days)) бесплатно"
        }
        return "Оформить подписку"
    }

    // MARK: - Loading / Unavailable States

    private var productsLoadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(accentGreen)
                .scaleEffect(1.4)
            Text("Загружаем тарифы…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(height: 120)
    }

    private var productsUnavailableState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.orange)
            Text("Тарифы недоступны")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text("Проверьте интернет-соединение и попробуйте снова")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Повторить") {
                Task { await subscriptionManager.loadProducts() }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(accentGreen)
        }
        .padding(24)
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Restore & Legal

    private var restoreButton: some View {
        Button {
            Task { await subscriptionManager.restorePurchases() }
        } label: {
            Text("Восстановить покупки")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .underline()
        }
        .buttonStyle(.plain)
        .disabled(subscriptionManager.isLoading)
    }

    private var legalFooter: some View {
        Text("Подписка автоматически продлевается, если не отменить за 24 часа до окончания периода. Управление подписками — в настройках Apple ID.")
            .font(.caption2)
            .foregroundStyle(Color.white.opacity(0.3))
            .multilineTextAlignment(.center)
            .lineSpacing(2)
    }

    // MARK: - Helpers

    private func purchaseSelected() async {
        guard let product = subscriptionManager.products.first(where: { $0.id == selectedProductID })
        else { return }
        await subscriptionManager.purchase(product)
    }

    /// Format a Decimal price with the given ISO currency code for display.
    private func formattedPrice(_ amount: Decimal, currencyCode: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.maximumFractionDigits = 0
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }

    private func daysString(_ n: Int) -> String {
        switch n % 10 {
        case 1 where n % 100 != 11: return "день"
        case 2...4 where !(11...14).contains(n % 100): return "дня"
        default: return "дней"
        }
    }
}

// MARK: - Preview

#Preview {
    PaywallView()
        .environment(AppState())
}
