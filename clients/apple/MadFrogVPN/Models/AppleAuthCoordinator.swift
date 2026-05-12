import Foundation
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// UIKit/AppKit-backed Sign in with Apple coordinator.
///
/// SwiftUI's `SignInWithAppleButton` relies on the system finding a presentation
/// anchor automatically. On iPad in iPhone-compatibility mode (which is how an
/// iPhone-only app runs on iPad), that anchor lookup occasionally returns the
/// wrong scene and the system auth sheet never presents — the button appears
/// to do "nothing", which is exactly what App Review reported on iPad Air M3.
///
/// This coordinator runs `ASAuthorizationController` directly with an explicit
/// `presentationContextProvider`, eliminating that ambiguity.
final class AppleAuthCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    @MainActor
    static func signIn(into app: AppState) async {
        let coordinator = AppleAuthCoordinator()
        await coordinator.run(into: app)
    }

    // Holds the coordinator alive until completion, and bridges callbacks to async.
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential?, Error>?
    private var keepAlive: AppleAuthCoordinator?

    @MainActor
    private func run(into app: AppState) async {
        keepAlive = self
        defer { keepAlive = nil }

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        // Both scopes — single-scope requests have known iPadOS regressions.
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        do {
            let credential: ASAuthorizationAppleIDCredential? = try await withCheckedThrowingContinuation { cont in
                self.continuation = cont
                controller.performRequests()
            }
            guard let credential else { return }
            await app.signInWithApple(credential: credential)
        } catch let error as NSError where error.code == ASAuthorizationError.canceled.rawValue {
            // User cancelled — silent.
        } catch {
            AppLogger.app.error("apple: sign-in failed: \(String(describing: error), privacy: .public)")
            app.errorMessage = String(localized: "onboarding.signin_failed")
        }
    }

    // MARK: - ASAuthorizationControllerDelegate

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        continuation?.resume(returning: credential)
        continuation = nil
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    // MARK: - ASAuthorizationControllerPresentationContextProviding

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        #if os(iOS) || os(tvOS) || os(visionOS)
        // Pick the foregrounded key window. On iPad in iPhone-compat mode the
        // default lookup sometimes lands on a non-key UIWindow — being explicit
        // about the active scene fixes presentation reliability.
        let active = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        if let key = active.flatMap(\.windows).first(where: { $0.isKeyWindow }) {
            return key
        }
        if let any = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first {
            return any
        }
        return ASPresentationAnchor()
        #elseif os(macOS)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
