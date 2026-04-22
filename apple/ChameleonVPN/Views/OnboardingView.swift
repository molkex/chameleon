import SwiftUI
import AuthenticationServices

struct OnboardingView: View {
    @Environment(AppState.self) private var app
    @Environment(ThemeManager.self) private var themeManager
    private var theme: Theme { themeManager.current }

    @State private var showTerms = false
    @State private var showPrivacy = false
    @State private var showEmailSignIn = false

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(minHeight: 40)

                // Hero logo.
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: theme.accent.opacity(0.22), radius: 20, x: 0, y: 8)

                Spacer().frame(height: 18)

                Text(L10n.Onboarding.title)
                    .font(theme.displayFont(size: 26, weight: .black))
                    .foregroundStyle(theme.textPrimary)

                Spacer().frame(height: 4)

                Text(L10n.Onboarding.subtitle)
                    .font(theme.font(size: 14))
                    .foregroundStyle(theme.textSecondary)

                Spacer().frame(height: 18)

                // Features — tighter.
                VStack(spacing: 8) {
                    FeatureRow(icon: "clock.badge.checkmark", text: L10n.Onboarding.featureTrial, theme: theme)
                    FeatureRow(icon: "lock.shield", text: L10n.Onboarding.featureNoLogs, theme: theme)
                    FeatureRow(icon: "bolt.fill", text: L10n.Onboarding.featureServers, theme: theme)
                }
                .padding(.horizontal, 40)

                Spacer(minLength: 20)

                // Auth buttons — all 48pt, same style. Apple visually primary
                // via accent-tinted stroke + filled icon; Google/Email secondary
                // with dimmer border. No more white-on-black mismatch.
                VStack(spacing: 10) {
                    SignInWithAppleButton(.continue) { request in
                        request.requestedScopes = [.email]
                    } onCompletion: { result in
                        switch result {
                        case .success(let auth):
                            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else { return }
                            Task { await app.signInWithApple(credential: credential) }
                        case .failure(let error):
                            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                                app.errorMessage = String(localized: "onboarding.signin_failed")
                            }
                        }
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 48)
                    .cornerRadius(12)
                    .disabled(app.isLoading)

                    authButton(
                        icon: { GoogleGLogo() },
                        text: L10n.Onboarding.signInWithGoogle,
                        action: { Task { await GoogleAuthCoordinator.signIn(into: app) } }
                    )

                    authButton(
                        icon: { Image(systemName: "envelope.fill").foregroundStyle(theme.accent) },
                        text: L10n.Onboarding.signInWithEmail,
                        action: { showEmailSignIn = true }
                    )
                }
                .padding(.horizontal, 24)

                Button {
                    Task { await app.signInAnonymous() }
                } label: {
                    Text(L10n.Onboarding.continueWithoutAccount)
                        .font(theme.font(size: 14, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                .disabled(app.isLoading)

                if app.isLoading {
                    ProgressView()
                        .tint(theme.textPrimary)
                        .padding(.top, 4)
                }

                // Legal footer — one line, smaller.
                HStack(spacing: 10) {
                    Button { showTerms = true } label: {
                        Text(L10n.Legal.termsTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textSecondary.opacity(0.8))
                    }
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary.opacity(0.5))
                    Button { showPrivacy = true } label: {
                        Text(L10n.Legal.privacyTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textSecondary.opacity(0.8))
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 20)
            }

            // Error toast
            if let error = app.errorMessage {
                VStack {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.red.opacity(0.8), in: Capsule())
                        .onTapGesture { app.errorMessage = nil }
                    Spacer()
                }
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: app.errorMessage != nil)
        .animation(.easeInOut(duration: 0.3), value: app.isLoading)
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
        .sheet(isPresented: $showEmailSignIn) {
            EmailSignInView()
                .environment(app)
                .environment(themeManager)
                .macSheetSize()
        }
    }
}

/// Google "G" mark — official four-color logo from Google's developer
/// press kit (g-logo.png). Google's branding guidelines explicitly allow
/// this asset for "Sign in with Google" buttons.
private struct GoogleGLogo: View {
    var body: some View {
        Image("GoogleG")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
    }
}

extension OnboardingView {
    /// Secondary auth-button style — matches the theme, consistent across
    /// Google/Email so they read as a pair subordinate to the white Apple button.
    @ViewBuilder
    fileprivate func authButton<Icon: View>(
        @ViewBuilder icon: () -> Icon,
        text: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon()
                    .frame(width: 20, height: 20)
                Text(text)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.textSecondary.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(app.isLoading)
    }
}

/// Wrapper to keep the existing call site working.
@ViewBuilder
private func googleMarkIcon() -> some View {
    GoogleGLogo()
}

private struct FeatureRow: View {
    let icon: String
    let text: LocalizedStringKey
    let theme: Theme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(theme.accent)
                .frame(width: 24)
            Text(text)
                .font(theme.font(size: 16))
                .foregroundStyle(theme.textPrimary.opacity(0.9))
            Spacer()
        }
    }
}
