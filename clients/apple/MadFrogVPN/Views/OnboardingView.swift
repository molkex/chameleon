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
    /// Build-36 single-flight gate. Set synchronously on tap so duplicate
    /// taps and competing login methods can't fire while one is in flight.
    /// `app.isLoading` only flips inside the async signIn methods, which
    /// leaves a window (Google sheet show, Apple system sheet) where it's
    /// still false — this state covers that gap.
    @State private var isAuthInFlight = false

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

                // Auth group: Apple + divider + chips read as one block.
                // `appleSignInButton` is the native `SignInWithAppleButton`
                // used plainly — see its doc comment for the build-72
                // rejection-fix history. Its `.disabled` is gated ONLY by
                // `app.isLoading` (reliably `defer`-scoped); it is
                // deliberately NOT coupled to `isAuthInFlight` — that
                // coupling, set by a competing gesture, was the build-59-71
                // self-disabling trap App Review kept hitting.
                VStack(spacing: 8) {
                    appleSignInButton
                        .frame(height: 52)
                        .disabled(app.isLoading)

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
                            guard !isAuthInFlight else { return }
                            isAuthInFlight = true
                            hapticLight()
                            Task {
                                await GoogleAuthCoordinator.signIn(into: app)
                                isAuthInFlight = false
                            }
                        }
                        chipButton(icon: {
                            Image(systemName: "envelope.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                        }, label: "Email") {
                            guard !isAuthInFlight else { return }
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
        // Build 59 (2026-05-13): prominent system alert for auth errors.
        // The red capsule above is supplementary — App Review reported "no
        // action took place" on iPad Air M3 (build 51/55), and a tiny capsule
        // at the top of the screen is easy to miss. A modal alert blocks the
        // UI until acknowledged, so even a quick reviewer sees the diagnostic.
        .alert(
            L10n.Onboarding.signInFailedTitle,
            isPresented: Binding(
                get: { app.errorMessage != nil },
                set: { if !$0 { app.errorMessage = nil } }
            ),
            actions: { Button("OK") { app.errorMessage = nil } },
            message: { Text(app.errorMessage ?? "") }
        )
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
        .disabled(app.isLoading || isAuthInFlight)
    }

    // MARK: - Apple sign-in button

    /// Native SwiftUI `SignInWithAppleButton`, used EXACTLY as Apple
    /// documents it — no extra gestures, no custom anchor plumbing, no
    /// `.disabled` coupling to our own flags.
    ///
    /// History — builds 51 / 53 / 59-71 were ALL rejected for Guideline
    /// 2.1(a), "the Sign in with Apple button was unresponsive":
    ///   - Build ≤49: SwiftUI button, automatic anchor.
    ///   - Build 53: UIKit `AppleAuthCoordinator` with an explicit anchor.
    ///   - Builds 59-71: native `SignInWithAppleButton` — but wrapped in a
    ///     `.simultaneousGesture(TapGesture)` "breadcrumb" that also set
    ///     `isAuthInFlight = true`. `SignInWithAppleButton` is a UIKit
    ///     `UIControl` behind a representable; a SwiftUI simultaneous
    ///     gesture on top of it swallowed the control's own
    ///     `touchUpInside` (so `onRequest` never fired, the system sheet
    ///     never presented) AND flipped the `.disabled(… || isAuthInFlight)`
    ///     wrapper — a self-disabling trap. The diagnostic hack WAS the bug.
    ///   - Build 72 (this): the button, plain. Apple's component handles
    ///     its own tap, debouncing, and presentation anchor. The only
    ///     additions are log breadcrumbs INSIDE `onRequest` / `onCompletion`
    ///     — those are the button's own callbacks, they cannot interfere
    ///     with touch delivery. `isAuthInFlight` is no longer touched here
    ///     (it stays for the Google/Email chips, which gate correctly
    ///     inside their action closures, not via a competing gesture).
    private var appleSignInButton: some View {
        SignInWithAppleButton(.signIn) { request in
            TunnelFileLogger.log("SIWA: onRequest fired", category: "auth")
            request.requestedScopes = [.fullName, .email]
        } onCompletion: { result in
            TunnelFileLogger.log("SIWA: onCompletion fired (result=\(result))", category: "auth")
            switch result {
            case .success(let auth):
                if let credential = auth.credential as? ASAuthorizationAppleIDCredential {
                    TunnelFileLogger.log("SIWA: got AppleIDCredential, calling app.signInWithApple", category: "auth")
                    Task { @MainActor in await app.signInWithApple(credential: credential) }
                } else {
                    TunnelFileLogger.log("SIWA: success but credential is not AppleIDCredential — \(type(of: auth.credential))", category: "auth")
                    app.errorMessage = String(localized: "onboarding.signin_failed")
                }
            case .failure(let error):
                let nsErr = error as NSError
                if nsErr.code == ASAuthorizationError.canceled.rawValue {
                    TunnelFileLogger.log("SIWA: user canceled (silent)", category: "auth")
                } else {
                    TunnelFileLogger.log("SIWA: failed — code=\(nsErr.code) domain=\(nsErr.domain) desc=\(nsErr.localizedDescription)", category: "auth")
                    app.errorMessage = String(localized: "onboarding.signin_failed")
                }
            }
        }
        .signInWithAppleButtonStyle(.white)
        .frame(height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("onboarding.continue_with_apple")
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
            guard !isAuthInFlight else { return }
            isAuthInFlight = true
            Task {
                await app.signInAnonymous()
                isAuthInFlight = false
            }
        } label: {
            Text(L10n.Onboarding.continueWithoutAccount)
                .font(theme.font(size: 13, weight: .medium))
                .foregroundStyle(theme.textSecondary.opacity(0.75))
                .underline(true, color: theme.textSecondary.opacity(0.4))
                .frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(app.isLoading || isAuthInFlight)
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
