import SwiftUI
import AuthenticationServices
#if os(iOS)
import UIKit
#endif

/// Light haptic tick for secondary button taps. No-op on macOS.
fileprivate func hapticLight() {
    #if os(iOS)
    let gen = UIImpactFeedbackGenerator(style: .light)
    gen.impactOccurred()
    #endif
}

/// First-launch onboarding. Big logo with a breathing halo, Apple as
/// primary CTA, Google + Email as secondary icon chips, guest as a
/// text link. Feature pills live above the CTAs to reassure the user.
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
                Spacer(minLength: 16)

                logo

                Spacer().frame(height: 20)

                Text(L10n.Onboarding.title)
                    .font(theme.displayFont(size: 34, weight: .black))
                    .foregroundStyle(theme.textPrimary)

                Spacer().frame(height: 10)

                Text(L10n.Onboarding.subtitle)
                    .font(theme.font(size: 15))
                    .foregroundStyle(theme.textSecondary)

                Spacer().frame(height: 28)

                featurePills

                Spacer(minLength: 24)

                // Auth group: Apple + divider + chips read as one block
                VStack(spacing: 8) {
                    SignInWithAppleButton(.continue) { request in
                        request.requestedScopes = [.email]
                    } onCompletion: { handleApple($0) }
                        .signInWithAppleButtonStyle(.white)
                        .frame(height: 52)
                        .cornerRadius(14)
                        .disabled(app.isLoading)
                        .onTapGesture { hapticLight() }

                    // "or" divider — text has solid bg so the line reads cleanly
                    ZStack {
                        Rectangle().fill(theme.textSecondary.opacity(0.18)).frame(height: 1)
                        Text(L10n.Onboarding.orLabel)
                            .font(theme.font(size: 11, weight: .medium))
                            .foregroundStyle(theme.textSecondary.opacity(0.8))
                            .tracking(1.5)
                            .padding(.horizontal, 12)
                            .background(theme.background)
                    }

                    HStack(spacing: 8) {
                        chipButton(icon: { GoogleGLogo(tint: theme.textPrimary) }, label: "Google") {
                            hapticLight()
                            Task { await GoogleAuthCoordinator.signIn(into: app) }
                        }
                        chipButton(icon: {
                            Image(systemName: "envelope.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                        }, label: "Email") {
                            hapticLight()
                            showEmailSignIn = true
                        }
                    }
                }
                .padding(.horizontal, 24)

                Spacer().frame(height: 14)

                guestButton

                if app.isLoading {
                    ProgressView().tint(theme.textPrimary).padding(.top, 6)
                }

                Spacer().frame(height: 14)

                HStack(spacing: 10) {
                    termsButton
                    Text("·").font(.system(size: 11)).foregroundStyle(theme.textSecondary.opacity(0.5))
                    privacyButton
                }
                .padding(.bottom, 20)
            }

            if let error = app.errorMessage {
                VStack {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.red.opacity(0.85), in: Capsule())
                        .onTapGesture { app.errorMessage = nil }
                    Spacer()
                }
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: app.errorMessage != nil)
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

    // MARK: - Logo with breathing halo

    private var logo: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Two out-of-phase sines so the halo feels alive, not metronomic.
            let slow = sin(t * 0.9)
            let fast = sin(t * 1.7 + 1.2)
            let pulse = 0.5 + 0.5 * slow              // 0..1
            let wobble = 0.5 + 0.5 * fast             // 0..1

            let innerOpacity = 0.22 + 0.18 * pulse    // 0.22..0.40
            let outerRadius: CGFloat = 190 + 22 * CGFloat(wobble)
            let blur: CGFloat = 14 + 6 * CGFloat(pulse)
            let scale: CGFloat = 0.98 + 0.04 * CGFloat(pulse)

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                theme.accent.opacity(innerOpacity),
                                theme.accent.opacity(0.0)
                            ],
                            center: .center,
                            startRadius: 36,
                            endRadius: outerRadius
                        )
                    )
                    .frame(width: 360, height: 360)
                    .blur(radius: blur)
                    .scaleEffect(scale)

                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
                    .shadow(color: theme.accent.opacity(0.24), radius: 22, x: 0, y: 12)
            }
        }
        .frame(height: 240)
    }

    // MARK: - Feature pills

    private var featurePills: some View {
        HStack(spacing: 8) {
            pill(icon: "clock.badge.checkmark", text: L10n.Onboarding.featureTrialShort)
            pill(icon: "lock.shield",           text: L10n.Onboarding.featureNoLogsShort)
            pill(icon: "bolt.fill",             text: L10n.Onboarding.featureFastShort)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func pill(icon: String, text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text(text)
                .font(theme.font(size: 11, weight: .medium))
                .foregroundStyle(theme.textPrimary.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.textSecondary.opacity(0.12), lineWidth: 1))
    }

    // MARK: - Secondary chips

    @ViewBuilder
    private func chipButton<Icon: View>(
        @ViewBuilder icon: () -> Icon, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon().frame(width: 20, height: 20)
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.textSecondary.opacity(0.28), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(app.isLoading)
    }

    // MARK: - Handlers

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
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

    private var termsButton: some View {
        Button { showTerms = true } label: {
            Text(L10n.Legal.termsTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary.opacity(0.8))
        }
    }

    private var privacyButton: some View {
        Button { showPrivacy = true } label: {
            Text(L10n.Legal.privacyTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary.opacity(0.8))
        }
    }

    private var guestButton: some View {
        Button {
            Task { await app.signInAnonymous() }
        } label: {
            Text(L10n.Onboarding.continueWithoutAccount)
                .font(theme.font(size: 13, weight: .medium))
                .foregroundStyle(theme.textSecondary.opacity(0.75))
                .underline(true, color: theme.textSecondary.opacity(0.4))
                .frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(app.isLoading)
    }
}

// MARK: - Google G (monochrome, tinted to match other icons)

/// Renders the Google G using SF-symbol-like glyph so it visually
/// matches the Email envelope instead of looking like a foreign paste.
/// We draw a simple "G" glyph in the theme text color — this keeps the
/// Google brand recognisable while respecting our dark UI.
private struct GoogleGLogo: View {
    let tint: Color

    var body: some View {
        Text("G")
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .frame(width: 20, height: 20)
    }
}
