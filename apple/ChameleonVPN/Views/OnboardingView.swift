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

                // App logo (from AppLogo imageset, sourced from AppIcon).
                // Rounded so it matches the home-screen icon's continuous corners.
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: theme.accent.opacity(0.25), radius: 18, x: 0, y: 8)

                Spacer().frame(height: 20)

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

                // Primary: Apple (system button — Apple requires specific style)
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
                .frame(height: 52)
                .cornerRadius(14)
                .padding(.horizontal, 24)
                .disabled(app.isLoading)

                Spacer().frame(height: 10)

                // Google — same visual weight as Apple (white rounded).
                Button {
                    Task { await GoogleAuthCoordinator.signIn(into: app) }
                } label: {
                    HStack(spacing: 10) {
                        googleMarkIcon()
                        Text(L10n.Onboarding.signInWithGoogle)
                            .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.13))
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .disabled(app.isLoading)

                Spacer().frame(height: 10)

                // Email — tertiary tint (matches the app's accent so users see
                // this is "ours", not a third-party).
                Button {
                    showEmailSignIn = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "envelope.fill")
                            .foregroundStyle(theme.accent)
                        Text(L10n.Onboarding.signInWithEmail)
                            .foregroundStyle(theme.textPrimary)
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .disabled(app.isLoading)

                // Quaternary: anonymous fallback. Kept small-caps text so
                // App Store review can't flag Apple Sign-In as the only path,
                // but visually subordinate — the account flows are the
                // recommended default.
                Button {
                    Task { await app.signInAnonymous() }
                } label: {
                    Text(L10n.Onboarding.continueWithoutAccount)
                        .font(theme.font(size: 14, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
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

/// Compact Google "G" mark, built with SF Symbols so we don't have to ship
/// raster assets. The real Google guidelines allow the text-only mark at
/// sizes this small; full logo would need an image asset.
@ViewBuilder
private func googleMarkIcon() -> some View {
    ZStack {
        Circle()
            .fill(Color.white)
            .frame(width: 22, height: 22)
        Text("G")
            .font(.system(size: 14, weight: .black, design: .rounded))
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.26, green: 0.52, blue: 0.96), // blue
                        Color(red: 0.20, green: 0.66, blue: 0.33), // green
                        Color(red: 0.98, green: 0.74, blue: 0.02), // yellow
                        Color(red: 0.93, green: 0.27, blue: 0.21)  // red
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
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
