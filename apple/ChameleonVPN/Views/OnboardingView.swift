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
                Spacer()

                // Hero logo — larger, dominant. Rounded to match iOS home icon.
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 140, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .shadow(color: theme.accent.opacity(0.28), radius: 24, x: 0, y: 10)

                Spacer().frame(height: 24)

                Text(L10n.Onboarding.title)
                    .font(theme.displayFont(size: 30, weight: .black))
                    .foregroundStyle(theme.textPrimary)

                Spacer().frame(height: 6)

                Text(L10n.Onboarding.subtitle)
                    .font(theme.font(size: 15))
                    .foregroundStyle(theme.textSecondary)

                Spacer().frame(height: 22)

                // Features
                VStack(spacing: 10) {
                    FeatureRow(icon: "clock.badge.checkmark", text: L10n.Onboarding.featureTrial, theme: theme)
                    FeatureRow(icon: "lock.shield", text: L10n.Onboarding.featureNoLogs, theme: theme)
                    FeatureRow(icon: "bolt.fill", text: L10n.Onboarding.featureServers, theme: theme)
                }
                .padding(.horizontal, 36)

                Spacer()

                // Primary: Apple — the only bold, opaque button. Apple HIG
                // requires Sign in with Apple be visually at-least-equal to
                // other sign-in methods, and we intentionally make it the
                // clear first choice. 54pt tall, biggest weight.
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
                .frame(height: 54)
                .cornerRadius(14)
                .padding(.horizontal, 24)
                .disabled(app.isLoading)

                Spacer().frame(height: 12)

                // Secondary: Google + Email, both transparent with subtle
                // border. They visually read as "alternatives" — same role,
                // subordinate to Apple.
                HStack(spacing: 10) {
                    Button {
                        Task { await GoogleAuthCoordinator.signIn(into: app) }
                    } label: {
                        HStack(spacing: 8) {
                            googleMarkIcon()
                            Text(L10n.Onboarding.signInWithGoogle)
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(theme.textSecondary.opacity(0.35), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(app.isLoading)

                    Button {
                        showEmailSignIn = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope.fill")
                                .foregroundStyle(theme.accent)
                            Text(L10n.Onboarding.signInWithEmail)
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(theme.textSecondary.opacity(0.35), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(app.isLoading)
                }
                .padding(.horizontal, 24)

                // Tertiary: guest — pure text link, clear affordance as
                // "skip this, just let me in". Users can upgrade later
                // via Settings → Link account (not yet implemented).
                Button {
                    Task { await app.signInAnonymous() }
                } label: {
                    Text(L10n.Onboarding.continueWithoutAccount)
                        .font(theme.font(size: 15, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .disabled(app.isLoading)

                if app.isLoading {
                    ProgressView()
                        .tint(theme.textPrimary)
                        .padding(.top, 8)
                }

                Spacer().frame(height: 8)

                VStack(spacing: 6) {
                    Text(L10n.Onboarding.terms)
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    HStack(spacing: 16) {
                        Button { showTerms = true } label: {
                            Text(L10n.Legal.termsTitle)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(theme.accent)
                        }
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(theme.textSecondary.opacity(0.5))
                        Button { showPrivacy = true } label: {
                            Text(L10n.Legal.privacyTitle)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(theme.accent)
                        }
                    }
                }

                Spacer().frame(height: 40)
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
            .frame(width: 20, height: 20)
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
