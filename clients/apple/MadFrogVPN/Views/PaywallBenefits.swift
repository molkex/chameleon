import SwiftUI

/// B1 (PRODUCT-MATURITY-LOOP, 2026-06-21): a shared value-prop block for both
/// paywalls (StoreKit + FreeKassa web), which were bare price lists with no
/// pitch. Bullets are feature/trust-focused and accurate to the product (1
/// device, no over-claiming); "no auto-renew" is framed as a positive because
/// the subs are non-renewing — a genuine "no surprise charges" differentiator.
struct PaywallBenefits: View {
    let theme: Theme

    private struct Benefit: Identifiable {
        let id: String
        let icon: String
        let text: LocalizedStringKey
        let highlight: Bool
    }

    private var benefits: [Benefit] {
        [
            Benefit(id: "nologs",  icon: "lock.shield.fill", text: L10n.PaywallBenefits.noLogs,  highlight: false),
            Benefit(id: "fast",    icon: "bolt.fill",        text: L10n.PaywallBenefits.fast,    highlight: false),
            Benefit(id: "unblock", icon: "globe",            text: L10n.PaywallBenefits.unblock, highlight: false),
            Benefit(id: "noads",   icon: "nosign",           text: L10n.PaywallBenefits.noAds,   highlight: false),
            Benefit(id: "norenew", icon: "checkmark.seal.fill", text: L10n.PaywallBenefits.noRenew, highlight: true),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(benefits) { b in
                HStack(spacing: 12) {
                    Image(systemName: b.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(b.highlight ? theme.accent : theme.textSecondary)
                        .frame(width: 22)
                    Text(b.text)
                        .font(theme.font(size: 14, weight: b.highlight ? .semibold : .regular))
                        .foregroundStyle(b.highlight ? theme.textPrimary : theme.textSecondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: theme.cardCornerRadius)
                .fill(theme.surface)
        )
    }
}
