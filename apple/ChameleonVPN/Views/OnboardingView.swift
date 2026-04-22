import SwiftUI
import AuthenticationServices

struct OnboardingView: View {
    @Environment(AppState.self) private var app
    @Environment(ThemeManager.self) private var themeManager
    private var theme: Theme { themeManager.current }

    @State private var showTerms = false
    @State private var showPrivacy = false

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo
                ZStack {
                    Circle()
                        .fill(theme.accent.opacity(0.18))
                        .frame(width: 128, height: 128)

                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 54, weight: .bold))
                        .foregroundStyle(theme.accent)
                }

                Spacer().frame(height: 32)

                Text(L10n.Onboarding.title)
                    .font(theme.displayFont(size: 34, weight: .black))
                    .foregroundStyle(theme.textPrimary)

                Spacer().frame(height: 8)

                Text(L10n.Onboarding.subtitle)
                    .font(theme.font(size: 18))
                    .foregroundStyle(theme.textSecondary)

                Spacer()

                // Features
                VStack(spacing: 14) {
                    FeatureRow(icon: "clock.badge.checkmark", text: L10n.Onboarding.featureTrial, theme: theme)
                    FeatureRow(icon: "lock.shield", text: L10n.Onboarding.featureNoLogs, theme: theme)
                    FeatureRow(icon: "bolt.fill", text: L10n.Onboarding.featureServers, theme: theme)
                }
                .padding(.horizontal, 32)

                Spacer().frame(height: 48)

                // Sign in with Apple
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.email]
                } onCompletion: { result in
                    switch result {
                    case .success(let auth):
                        guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else { return }
                        Task { await app.signInWithApple(credential: credential) }
                    case .failure(let error):
                        // User cancelled — don't show error
                        if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                            app.errorMessage = String(localized: "onboarding.signin_failed")
                        }
                    }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .cornerRadius(12)
                .padding(.horizontal, 24)
                .disabled(app.isLoading)

                Spacer().frame(height: 12)

                // Fallback: continue without an Apple account (device-bound trial).
                // Required so users without an Apple ID, or who decline Sign in
                // with Apple, can still use the app — otherwise we'd be blocking
                // a legitimate path and App Store review flags this.
                Button {
                    Task { await app.signInAnonymous() }
                } label: {
                    Text(L10n.Onboarding.continueWithoutAccount)
                        .font(theme.font(size: 15, weight: .medium))
                        .foregroundStyle(theme.textPrimary.opacity(0.85))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .disabled(app.isLoading)

                if app.isLoading {
                    ProgressView()
                        .tint(theme.textPrimary)
                        .padding(.top, 16)
                }

                Spacer().frame(height: 16)

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
