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
                    PaywallBenefits(theme: theme)   // B1: value pitch above the plans
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
            .navigationTitle(Text(L10n.WebPaywall.title))
            .iosInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.WebPaywall.close) { dismiss() }
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
            .alert(Text(L10n.WebPaywall.successTitle), isPresented: $showSuccess) {
                Button(L10n.WebPaywall.successOk) { dismiss() }
            } message: {
                Text(L10n.WebPaywall.successBody)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 48))
                .foregroundStyle(theme.accent)
            Text(L10n.WebPaywall.headerTitle)
                .font(theme.displayFont(size: 24, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            Text(L10n.WebPaywall.headerSubtitle)
                .font(theme.font(size: 14))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var planCards: some View {
        // A8: baseline = the costliest per-month plan (monthly); cards show their
        // saving vs it so a longer plan reads as the better deal.
        let baselinePerMonth = PlanPricing.baselinePerMonthRub(plans.map { ($0.priceRub, $0.days) })
        return VStack(spacing: 12) {
            ForEach(plans) { plan in
                WebPlanCard(
                    plan: plan,
                    isSelected: plan.id == selectedPlan,
                    baselinePerMonthRub: baselinePerMonth,
                    theme: theme
                )
                .onTapGesture {
                    selectedPlan = plan.id
                    // USR-09 Phase 2 — plan tap on web paywall. Mirrors
                    // PaywallView.planCards' paywall.product.tap so the
                    // funnel page can compare which products RU vs non-RU
                    // users hover on (sub-flow analytics, not "what they
                    // bought").
                    Task {
                        await app.eventTracker.log(
                            name: "paywall.plan.tap",
                            properties: [
                                "plan_id": plan.id,
                                "price_rub": plan.priceRub,
                                "storefront": "web",
                            ]
                        )
                    }
                }
            }
        }
    }

    private var emailField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L10n.WebPaywall.emailLabel)
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
            Text(L10n.WebPaywall.emailHint)
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
            Text(L10n.WebPaywall.methodLabel)
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
        if pendingPaymentID != nil { return "webpaywall.check_status".localized }
        if email.isEmpty { return "webpaywall.enter_email".localized }
        if !isEmailValid { return "webpaywall.email.invalid".localized }
        return "webpaywall.pay".localized
    }

    private var legalFooter: some View {
        VStack(spacing: 6) {
            Text(L10n.WebPaywall.legalText)
            HStack(spacing: 14) {
                Link(destination: URL(string: "https://madfrog.online/terms")!) {
                    Text(L10n.WebPaywall.legalTerms)
                }
                Link(destination: URL(string: "https://madfrog.online/privacy")!) {
                    Text(L10n.WebPaywall.legalPrivacy)
                }
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
        case "sbp": return "webpaywall.method.sbp".localized
        case "card": return "webpaywall.method.card".localized
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
            // USR-09 Phase 2 — paywall impression. Fired after the plans
            // call resolves so the property bag carries the actual count
            // (zero is a real signal: backend rejected the request or the
            // plans table is empty — we want both visible in the funnel).
            // Mirrors PaywallView.task's paywall.view but with storefront="web".
            await app.eventTracker.log(
                name: "paywall.view",
                properties: [
                    "plans": resp.plans.count,
                    "methods": resp.methods.count,
                    "storefront": "web",
                ]
            )
        } catch {
            errorMessage = "webpaywall.error.plans".localized
            // Failed fetch is still an impression — the user saw the
            // paywall, just got an error screen. Tag it separately so we
            // can spot a backend regression bricking the RU flow.
            await app.eventTracker.log(
                name: "paywall.view",
                properties: [
                    "plans": 0,
                    "methods": 0,
                    "storefront": "web",
                    "error": "fetch_plans_failed",
                ]
            )
        }
    }

    @MainActor
    private func initiate() async {
        guard let token = app.configStore.accessToken else {
            errorMessage = "webpaywall.error.auth".localized
            await app.eventTracker.log(
                name: "purchase.fail",
                properties: [
                    "plan_id": selectedPlan,
                    "method": selectedMethod,
                    "storefront": "web",
                    "stage": "preflight",
                    "reason": "no_access_token",
                ]
            )
            return
        }
        // If we already have a pending payment, re-open Safari and poll.
        if let pid = pendingPaymentID {
            await pollStatus()
            if pendingPaymentID == pid {
                errorMessage = "webpaywall.error.pending".localized
            }
            return
        }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        // USR-09 Phase 2 — purchase intent on the web flow. Mirrors
        // PaywallView.purchaseButton's purchase.start so the funnel
        // shows both flows side-by-side.
        await app.eventTracker.log(
            name: "purchase.start",
            properties: [
                "plan_id": selectedPlan,
                "method": selectedMethod,
                "storefront": "web",
            ]
        )

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
            // Step 2 of the web flow — we successfully created the
            // payment + handed off to Safari. The actual purchase
            // success/fail comes later via pollStatus (when the user
            // returns from the bank app). This is the "started checkout"
            // signal: useful drop-off metric vs purchase.success.
            await app.eventTracker.log(
                name: "purchase.handoff",
                properties: [
                    "plan_id": selectedPlan,
                    "method": selectedMethod,
                    "storefront": "web",
                    "payment_id": result.paymentId,
                ]
            )
        } catch APIError.unauthorized {
            errorMessage = "webpaywall.error.session".localized
            await app.eventTracker.log(
                name: "purchase.fail",
                properties: [
                    "plan_id": selectedPlan,
                    "method": selectedMethod,
                    "storefront": "web",
                    "stage": "initiate",
                    "reason": "unauthorized",
                ]
            )
        } catch {
            errorMessage = "webpaywall.error.payment".localized
            await app.eventTracker.log(
                name: "purchase.fail",
                properties: [
                    "plan_id": selectedPlan,
                    "method": selectedMethod,
                    "storefront": "web",
                    "stage": "initiate",
                    "reason": "\(error)",
                ]
            )
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
                // USR-09 Phase 2 — terminal success event for the web flow.
                await app.eventTracker.log(
                    name: "purchase.success",
                    properties: [
                        "plan_id": selectedPlan,
                        "method": selectedMethod,
                        "storefront": "web",
                        "payment_id": pid,
                    ]
                )
            }
        } catch {
            // Swallow — user can tap the button again to retry. The
            // fail event is intentionally NOT fired here — pollStatus
            // is called from scenePhase changes and would spam.
            // initiate()'s catch already fires purchase.fail for the
            // real failure modes.
        }
    }
}

private struct WebPlanCard: View {
    let plan: APIClient.PaymentPlan
    let isSelected: Bool
    let baselinePerMonthRub: Int
    let theme: Theme

    private var perMonth: Int {
        PlanPricing.perMonthRub(priceRub: plan.priceRub, days: plan.days)
    }
    private var savings: Int {
        PlanPricing.savingsPercent(perMonthRub: perMonth, baselinePerMonthRub: baselinePerMonthRub)
    }

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
                    // A8: quantified savings vs the monthly per-month price.
                    if savings > 0 {
                        Text(L10n.WebPaywall.planSave(savings))
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.accent.opacity(0.18))
                            .foregroundStyle(theme.accent)
                            .clipShape(Capsule())
                    }
                }
                Text(L10n.WebPaywall.planDaysOneDevice(plan.days))
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(plan.priceRub) ₽")
                    .font(theme.displayFont(size: 20, weight: .bold))
                    .foregroundStyle(theme.accent)
                // A8: per-month equivalent so longer plans read as cheaper.
                if perMonth > 0 {
                    Text(L10n.WebPaywall.planPerMonth(perMonth))
                        .font(theme.font(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
            }
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
