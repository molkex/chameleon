import SwiftUI

/// ACCT-IDENTITY (2026-06-01): non-destructive session-recovery sheet.
///
/// Shown (auto-presented from MainView on `app.needsReauth`) when an identity
/// user's session can no longer be silently refreshed — refresh token dead
/// after long dormancy, backend 404, or a revoked Apple credential. The user's
/// Keychain identity is INTACT; this only re-establishes a backend session. We
/// never demote to a fresh anonymous trial (the P0 this whole change fixes).
///
/// Recovery ladder surfaced here:
///   • Sign in with Apple — backend reclaims the SAME account by `sub`
///     (one Face ID for an already-authorized user).
///   • Email magic link (reuses `EmailSignInView`) — cross-device / last
///     resort when the Apple credential is gone.
/// Dismissing ("Later") keeps cached config working; the banner re-appears on
/// the next failed refresh.
struct ReauthView: View {
    @Environment(AppState.self) private var app
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    @State private var showEmail = false
    @State private var busy = false

    private var theme: Theme { themeManager.current }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer().frame(height: 24)
                ZStack {
                    Circle().fill(theme.accent.opacity(0.18)).frame(width: 88, height: 88)
                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                Spacer().frame(height: 24)

                Text(L10n.Reauth.title)
                    .font(theme.displayFont(size: 24, weight: .bold))
                    .foregroundStyle(theme.textPrimary)

                Spacer().frame(height: 8)

                Text(L10n.Reauth.subtitle)
                    .font(theme.font(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer().frame(height: 28)

                // Step 2 — Apple re-auth (primary for an Apple identity).
                if app.configStore.authProvider == "apple" {
                    Button {
                        Task {
                            busy = true
                            await app.reauthenticateWithApple()
                            busy = false
                            if !app.needsReauth { dismiss() }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().tint(.white) }
                            Image(systemName: "apple.logo")
                            Text(L10n.Reauth.apple)
                                .font(theme.font(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(theme.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .padding(.horizontal, 24)

                    Spacer().frame(height: 12)
                }

                // Step 3 — email magic link (cross-device / last resort).
                Button {
                    showEmail = true
                } label: {
                    Text(L10n.Reauth.email)
                        .font(theme.font(size: 16, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)

                Spacer()

                Button { dismiss() } label: {
                    Text(L10n.Reauth.later)
                        .font(theme.font(size: 15))
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
                Spacer().frame(height: 20)
            }
        }
        .sheet(isPresented: $showEmail) {
            EmailSignInView()
                .environment(app)
                .environment(themeManager)
                .macSheetSize()
                .macCloseButton { showEmail = false }
        }
    }
}
