import SwiftUI
import AuthenticationServices

struct OnboardingView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.cyan.opacity(0.3), .blue.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 120, height: 120)

                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(
                            LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom)
                        )
                }

                Spacer().frame(height: 32)

                Text("Chameleon")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)

                Spacer().frame(height: 8)

                Text("Secure VPN")
                    .font(.title3)
                    .foregroundStyle(.gray)

                Spacer()

                // Features
                VStack(spacing: 14) {
                    FeatureRow(icon: "clock.badge.checkmark", text: "3 days free trial")
                    FeatureRow(icon: "lock.shield", text: "No logs policy")
                    FeatureRow(icon: "bolt.fill", text: "Fast & reliable servers")
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
                            app.errorMessage = "Sign in failed. Please try again."
                        }
                    }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .cornerRadius(12)
                .padding(.horizontal, 24)

                if app.isLoading {
                    ProgressView()
                        .tint(.white)
                        .padding(.top, 16)
                }

                Spacer().frame(height: 16)

                Text("By continuing you agree to our Terms of Service and Privacy Policy")
                    .font(.caption2)
                    .foregroundStyle(.gray.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

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
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.cyan)
                .frame(width: 24)
            Text(text)
                .font(.body)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
    }
}
