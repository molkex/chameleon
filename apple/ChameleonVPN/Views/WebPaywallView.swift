import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// FreeKassa paywall. Opens checkout in external Safari (not SFSafariViewController),
/// then polls /api/mobile/payment/status while the app is active so the UI flips
/// to "success" the moment the webhook credits the ledger.
///
/// Apple treats `UIApplication.shared.open(url)` as a user-initiated visit to a
/// third-party website — not an in-app purchase — which is the distinction that
/// keeps SBP/card payments compliant in the App Store (same pattern InConnect uses).
struct WebPaywallView: View {
    @Environment(AppState.self) private var app
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var plans: [APIClient.PaymentPlan] = []
    @State private var methods: [String] = []
    @State private var selectedPlan: String = ""
    @State private var selectedMethod: String = "sbp"
    @State private var email: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var pendingPaymentID: String?
    @State private var showSuccess = false

    private var theme: Theme { themeManager.current }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    if plans.isEmpty && isLoading {
                        ProgressView().padding(.top, 40)
                    } else {
                        planCards
                        emailField
                        methodPicker
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    payButton
                    legalFooter
                }
                .padding()
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Подписка")
            .iosInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .task { await loadPlans() }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active, pendingPaymentID != nil {
                    Task { await pollStatus() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .paymentReturnFromLink)) { _ in
                if pendingPaymentID != nil {
                    Task { await pollStatus() }
                }
            }
            .alert("Оплата получена", isPresented: $showSuccess) {
                Button("OK") { dismiss() }
            } message: {
                Text("Подписка активирована. Спасибо!")
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 48))
                .foregroundStyle(theme.accent)
            Text("Безлимитный VPN")
                .font(theme.displayFont(size: 24, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            Text("Быстрые сервера. Оплата по СБП, картой или SberPay.")
                .font(theme.font(size: 14))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var planCards: some View {
        VStack(spacing: 12) {
            ForEach(plans) { plan in
                WebPlanCard(
                    plan: plan,
                    isSelected: plan.id == selectedPlan,
                    theme: theme
                )
                .onTapGesture { selectedPlan = plan.id }
            }
        }
    }

    private var emailField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Email для чека")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(theme.textPrimary)
                Text("*")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.red)
            }
            TextField("", text: $email)
                .iosNoAutocapitalization()
                .iosEmailKeyboard()
                .autocorrectionDisabled()
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .fill(theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .strokeBorder(emailBorderColor, lineWidth: 1)
                )
                .foregroundStyle(theme.textPrimary)
            Text("Обязательно — чек по 54-ФЗ прилетит сюда после оплаты")
                .font(.caption2)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private var emailBorderColor: Color {
        if email.isEmpty { return .clear }
        return isEmailValid ? .green.opacity(0.5) : .red.opacity(0.6)
    }

    private var methodPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Способ оплаты")
                .font(.footnote)
                .foregroundStyle(theme.textSecondary)
            HStack(spacing: 8) {
                ForEach(methods, id: \.self) { method in
                    Button {
                        selectedMethod = method
                    } label: {
                        Text(methodLabel(method))
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: theme.cornerRadius)
                                    .fill(selectedMethod == method ? theme.accent.opacity(0.2) : theme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: theme.cornerRadius)
                                    .strokeBorder(selectedMethod == method ? theme.accent : .clear, lineWidth: 2)
                            )
                            .foregroundStyle(theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var payButton: some View {
        let disabled = isLoading || plans.isEmpty || selectedPlan.isEmpty || !isEmailValid
        return Button {
            Task { await initiate() }
        } label: {
            HStack {
                if isLoading { ProgressView().tint(theme.background) }
                Text(payButtonTitle)
                    .font(theme.font(size: 17, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(disabled ? theme.surface : theme.accent)
            .foregroundStyle(disabled ? theme.textSecondary : theme.background)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
        .disabled(disabled)
    }

    private var payButtonTitle: String {
        if pendingPaymentID != nil { return "Проверить статус" }
        if email.isEmpty { return "Введите email" }
        if !isEmailValid { return "Email некорректный" }
        return "Оплатить"
    }

    private var legalFooter: some View {
        VStack(spacing: 6) {
            Text("Нажимая «Оплатить», вы соглашаетесь с условиями использования и политикой конфиденциальности.")
            HStack(spacing: 14) {
                Link("Условия", destination: URL(string: "https://madfrog.online/terms")!)
                Link("Конфиденциальность", destination: URL(string: "https://madfrog.online/privacy")!)
            }
            .font(.caption2.weight(.medium))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, 8)
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isEmailValid: Bool {
        let value = trimmedEmail
        guard value.count >= 5, !value.contains(" ") else { return false }
        // Simple RFC-ish check: exactly one @, dot in domain part, TLD ≥ 2 chars.
        let parts = value.split(separator: "@")
        guard parts.count == 2 else { return false }
        let domain = parts[1]
        guard let lastDot = domain.lastIndex(of: ".") else { return false }
        let tld = domain[domain.index(after: lastDot)...]
        return tld.count >= 2 && !parts[0].isEmpty
    }

    private func methodLabel(_ method: String) -> String {
        switch method {
        case "sbp": return "СБП"
        case "card": return "Карта"
        case "sberpay": return "SberPay"
        default: return method.uppercased()
        }
    }

    @MainActor
    private func loadPlans() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let resp = try await app.apiClient.fetchPlans()
            plans = resp.plans
            methods = resp.methods
            if selectedPlan.isEmpty, let first = resp.plans.first {
                selectedPlan = first.id
            }
            if !methods.contains(selectedMethod), let first = methods.first {
                selectedMethod = first
            }
        } catch {
            errorMessage = "Не удалось загрузить тарифы"
        }
    }

    @MainActor
    private func initiate() async {
        guard let token = app.configStore.accessToken else {
            errorMessage = "Требуется авторизация"
            return
        }
        // If we already have a pending payment, re-open Safari and poll.
        if let pid = pendingPaymentID {
            await pollStatus()
            if pendingPaymentID == pid {
                errorMessage = "Платёж ещё обрабатывается…"
            }
            return
        }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await app.apiClient.initiatePayment(
                plan: selectedPlan,
                method: selectedMethod,
                email: trimmedEmail,
                accessToken: token
            )
            pendingPaymentID = result.paymentId
            if let url = URL(string: result.paymentURL) {
                await PlatformURLOpener.open(url)
            }
        } catch APIError.unauthorized {
            errorMessage = "Сессия истекла, войдите заново"
        } catch {
            errorMessage = "Не удалось создать платёж"
        }
    }

    @MainActor
    private func pollStatus() async {
        guard let pid = pendingPaymentID,
              let token = app.configStore.accessToken else { return }
        do {
            let status = try await app.apiClient.paymentStatus(paymentId: pid, accessToken: token)
            if status.status == "completed" {
                pendingPaymentID = nil
                await app.refreshAfterPurchase()
                showSuccess = true
            }
        } catch {
            // Swallow — user can tap the button again to retry.
        }
    }
}

private struct WebPlanCard: View {
    let plan: APIClient.PaymentPlan
    let isSelected: Bool
    let theme: Theme

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(plan.title)
                        .font(theme.font(size: 17, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    if let badge = plan.badge, !badge.isEmpty {
                        Text(badge)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.accent.opacity(0.2))
                            .foregroundStyle(theme.accent)
                            .clipShape(Capsule())
                    }
                }
                Text("\(plan.days) дн. на 1 устройство")
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Text("\(plan.priceRub) ₽")
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
