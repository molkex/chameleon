import SwiftUI
import AuthenticationServices

struct ActivationView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    @State private var _appleHelper: _AppleSignInHelper? = nil

    // Entrance animations
    @State private var logoScale: CGFloat = 0.5
    @State private var logoOpacity: Double = 0
    @State private var contentOpacity: Double = 0
    @State private var shakeOffset: CGFloat = 0

    // Lightweight breathing (1 repeating animation, near-zero CPU)
    @State private var breathScale: CGFloat = 1.0

    private var accentGreen: Color { Color(red: 0.2, green: 0.84, blue: 0.42) }
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            // ── Background ──────────────────────────────────────────────
            // Base gradient — not flat black/white
            LinearGradient(
                colors: isDark
                    ? [Color(red: 0.05, green: 0.07, blue: 0.13),
                       Color(red: 0.04, green: 0.04, blue: 0.07)]
                    : [Color(red: 0.96, green: 0.97, blue: 1.0),
                       Color(red: 0.92, green: 0.95, blue: 1.0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Blue/indigo halo behind logo — top center
            RadialGradient(
                colors: [
                    Color(red: 0.25, green: 0.45, blue: 1.0).opacity(isDark ? 0.18 : 0.10),
                    .clear
                ],
                center: .init(x: 0.5, y: 0.15),
                startRadius: 20,
                endRadius: 340
            )
            .ignoresSafeArea()

            // Green glow at bottom
            RadialGradient(
                colors: [accentGreen.opacity(isDark ? 0.24 : 0.13), .clear],
                center: .init(x: 0.5, y: 1.2),
                startRadius: 40,
                endRadius: 560
            )
            .ignoresSafeArea()

            // ── Content ─────────────────────────────────────────────────
            VStack(spacing: 0) {
                Spacer()

                logoSection
                    .padding(.bottom, 36)

                titleSection
                    .opacity(contentOpacity)

                Spacer()

                actionsSection
                    .opacity(contentOpacity)

                errorSection
                    .offset(x: shakeOffset)

                Spacer().frame(height: 48)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.65).delay(0.1)) {
                logoScale = 1.0; logoOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.35)) {
                contentOpacity = 1.0
            }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true).delay(0.8)) {
                breathScale = 1.035
            }
        }
        .onChange(of: appState.errorMessage) { _, e in if e != nil { shakeAnimation() } }
    }

    // MARK: - Logo

    private var logoSection: some View {
        ZStack {
            // Outer breathing glow ring
            Circle()
                .fill(accentGreen.opacity(isDark ? 0.12 : 0.08))
                .frame(width: 168, height: 168)
                .scaleEffect(breathScale)
                .blur(radius: 8)

            // Inner blue shimmer — static, creates depth
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.3, green: 0.5, blue: 1.0).opacity(isDark ? 0.10 : 0.06),
                            .clear
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 70
                    )
                )
                .frame(width: 140, height: 140)

            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                .shadow(
                    color: accentGreen.opacity(isDark ? 0.45 : 0.20),
                    radius: 28, y: 10
                )
                .shadow(
                    color: Color(red: 0.2, green: 0.4, blue: 1.0).opacity(isDark ? 0.20 : 0.08),
                    radius: 40, y: -4
                )
                .scaleEffect(breathScale * logoScale)
                .opacity(logoOpacity)
        }
    }

    // MARK: - Title

    private var titleSection: some View {
        VStack(spacing: 10) {
            Text("MadFrog VPN")
                .font(.largeTitle.bold())
                .foregroundStyle(isDark ? .white : .primary)

            Text("Разблокируй интернет за 1 минуту")
                .font(.subheadline)
                .foregroundStyle(isDark
                    ? Color.white.opacity(0.55)
                    : Color.primary.opacity(0.55))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 10) {

            // PRIMARY: try free — creates new account
            Button {
                Task { await triggerApple(intent: .trial) }
            } label: {
                Group {
                    if appState.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        VStack(spacing: 3) {
                            Text("Попробовать бесплатно")
                                .font(.headline)
                            Text("3 дня · без привязки карты")
                                .font(.caption)
                                .opacity(0.85)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(.white)
                .background(
                    LinearGradient(
                        colors: [accentGreen, Color(red: 0.12, green: 0.70, blue: 0.36)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .shadow(color: accentGreen.opacity(0.45), radius: 14, y: 5)
            }
            .disabled(appState.isLoading)

            // SECONDARY: have account → Apple Sign In (lookup existing)
            Button {
                Task { await triggerApple(intent: .login) }
            } label: {
                Group {
                    if appState.isLoading {
                        ProgressView().tint(isDark ? .white : .primary)
                    } else {
                        Text("У меня есть аккаунт")
                            .font(.subheadline.weight(.medium))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(isDark ? Color.white.opacity(0.85) : Color.primary)
                .background(
                    isDark
                        ? AnyShapeStyle(Color.white.opacity(0.07))
                        : AnyShapeStyle(Color.black.opacity(0.04)),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12),
                            lineWidth: 1
                        )
                )
            }
            .disabled(appState.isLoading)

            // Apple badge
            HStack(spacing: 4) {
                Image(systemName: "apple.logo")
                    .font(.caption2)
                Text("Авторизация через Apple Sign In")
                    .font(.caption2)
            }
            .foregroundStyle(isDark ? Color.white.opacity(0.28) : Color.primary.opacity(0.35))
            .padding(.top, 4)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Error

    private var errorSection: some View {
        Group {
            if let error = appState.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.subheadline)
                    Text(error).foregroundStyle(.red).font(.caption)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.red.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 32).padding(.top, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: appState.errorMessage)
    }

    // MARK: - Auth

    private enum AuthIntent { case trial, login }

    private func triggerApple(intent: AuthIntent) async {
        appState.errorMessage = nil
        let scopes: [ASAuthorization.Scope] = intent == .trial ? [.fullName, .email] : []
        let cred: ASAuthorizationAppleIDCredential
        do {
            cred = try await withCheckedThrowingContinuation { cont in
                let helper = _AppleSignInHelper(continuation: cont)
                _appleHelper = helper
                helper.trigger(scopes: scopes)
            }
        } catch {
            _appleHelper = nil
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                appState.errorMessage = error.localizedDescription
            }
            return
        }
        _appleHelper = nil

        guard let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            appState.errorMessage = "Не удалось получить данные Apple"
            return
        }

        await appState.authenticateWithApple(identityToken: token, userIdentifier: cred.user)
    }

    private func shakeAnimation() {
        withAnimation(.spring(response: 0.1, dampingFraction: 0.2)) { shakeOffset = -10 }
        withAnimation(.spring(response: 0.1, dampingFraction: 0.2).delay(0.1)) { shakeOffset = 10 }
        withAnimation(.spring(response: 0.1, dampingFraction: 0.2).delay(0.2)) { shakeOffset = -6 }
        withAnimation(.spring(response: 0.15, dampingFraction: 0.4).delay(0.3)) { shakeOffset = 0 }
    }
}

// MARK: - Apple Sign In programmatic helper

final class _AppleSignInHelper: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    private let continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>

    init(continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>) {
        self.continuation = continuation
    }

    func trigger(scopes: [ASAuthorization.Scope]) {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = scopes
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func authorizationController(controller: ASAuthorizationController,
                                  didCompleteWithAuthorization authorization: ASAuthorization) {
        if let cred = authorization.credential as? ASAuthorizationAppleIDCredential {
            continuation.resume(returning: cred)
        } else {
            continuation.resume(throwing: ASAuthorizationError(.unknown))
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                  didCompleteWithError error: Error) {
        continuation.resume(throwing: error)
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? UIWindow()
    }
}
