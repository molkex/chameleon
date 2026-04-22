import SwiftUI

/// Shown the first time the user taps Connect and no VPN profile is installed.
/// Explains *why* the system alert that iOS is about to present matters, so
/// approval rates go up and App Review stops flagging cold prompts.
///
/// The system alert itself is triggered by `VPNManager.connect()` →
/// `saveToPreferences()`. This primer is strictly informational; once the
/// user taps "Continue", we proceed with the normal connect flow.
struct VPNPermissionPrimerView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    let onContinue: () -> Void

    private var theme: Theme { themeManager.current }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 20)

                ZStack {
                    Circle()
                        .fill(theme.accent.opacity(0.18))
                        .frame(width: 96, height: 96)
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(theme.accent)
                }

                Spacer().frame(height: 28)

                Text(L10n.Primer.title)
                    .font(theme.displayFont(size: 26, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Spacer().frame(height: 10)

                Text(L10n.Primer.subtitle)
                    .font(theme.font(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer().frame(height: 28)

                VStack(spacing: 16) {
                    PrimerRow(icon: "1.circle.fill",
                              text: L10n.Primer.step1,
                              theme: theme)
                    PrimerRow(icon: "2.circle.fill",
                              text: L10n.Primer.step2,
                              theme: theme)
                    PrimerRow(icon: "3.circle.fill",
                              text: L10n.Primer.step3,
                              theme: theme)
                }
                .padding(.horizontal, 28)

                Spacer()

                Button {
                    dismiss()
                    onContinue()
                } label: {
                    Text(L10n.Primer.continueButton)
                        .font(theme.font(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(theme.accent, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)

                Spacer().frame(height: 12)

                Button {
                    dismiss()
                } label: {
                    Text(L10n.Primer.notNow)
                        .font(theme.font(size: 15))
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer().frame(height: 16)
            }
        }
    }
}

private struct PrimerRow: View {
    let icon: String
    let text: LocalizedStringKey
    let theme: Theme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 28)
            Text(text)
                .font(theme.font(size: 15))
                .foregroundStyle(theme.textPrimary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}
