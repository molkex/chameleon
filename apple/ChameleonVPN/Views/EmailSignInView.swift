import SwiftUI

/// Passwordless email sign-in. User enters email, we ask the backend to send
/// a magic link. When the link is tapped on this device, the Universal Link
/// handler in `ChameleonApp` routes the token into `AppState.consumeMagicToken`.
///
/// The screen is a bottom sheet presented from Onboarding. No password input,
/// by design: we rejected classic email+password for MVP.
struct EmailSignInView: View {
    @Environment(AppState.self) private var app
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var showCheckEmail: Bool = false
    @State private var sentToEmail: String = ""

    private var theme: Theme { themeManager.current }

    private var isValid: Bool {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard e.count >= 5, !e.contains(" ") else { return false }
        let parts = e.split(separator: "@")
        guard parts.count == 2 else { return false }
        let domain = parts[1]
        guard let lastDot = domain.lastIndex(of: ".") else { return false }
        return domain.distance(from: domain.index(after: lastDot), to: domain.endIndex) >= 2
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            if showCheckEmail {
                checkEmailState
            } else {
                formState
            }
        }
    }

    private var formState: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 20)
            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.18))
                    .frame(width: 88, height: 88)
                Image(systemName: "envelope.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            Spacer().frame(height: 24)

            Text(L10n.Magic.title)
                .font(theme.displayFont(size: 24, weight: .bold))
                .foregroundStyle(theme.textPrimary)

            Spacer().frame(height: 8)

            Text(L10n.Magic.subtitle)
                .font(theme.font(size: 15))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer().frame(height: 28)

            TextField(L10n.Magic.emailPlaceholder, text: $email)
                .iosEmailKeyboard()
                .iosNoAutocapitalization()
                .autocorrectionDisabled()
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .fill(theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .strokeBorder(isValid ? theme.accent.opacity(0.4) : .clear, lineWidth: 1)
                )
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 24)

            Spacer().frame(height: 18)

            Button {
                Task {
                    let sent = await app.requestMagicLink(email: email)
                    if sent {
                        sentToEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
                        withAnimation { showCheckEmail = true }
                    }
                }
            } label: {
                HStack {
                    if app.isLoading {
                        ProgressView().tint(.white)
                    }
                    Text(L10n.Magic.send)
                        .font(theme.font(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(isValid ? theme.accent : theme.surface, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(!isValid || app.isLoading)
            .padding(.horizontal, 24)

            Spacer()
        }
    }

    private var checkEmailState: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.18))
                    .frame(width: 96, height: 96)
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            Spacer().frame(height: 28)
            Text(L10n.Magic.checkEmailTitle)
                .font(theme.displayFont(size: 24, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 12)
            Text(String(format: String(localized: "magic.check_email.body"), sentToEmail))
                .font(theme.font(size: 15))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text(L10n.Magic.checkEmailClose)
                    .font(theme.font(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            Spacer().frame(height: 24)
        }
    }
}
