import Foundation
#if canImport(UIKit)
import UIKit
#endif
import GoogleSignIn

/// Wraps GoogleSignIn SDK so the view layer doesn't touch SDK types directly.
/// Picks the top-most presenting view controller, runs the SDK flow, and hands
/// the resulting ID token off to `AppState.signInWithGoogle`.
enum GoogleAuthCoordinator {
    /// Start the Google Sign-In flow. Safe to call from a Button action in a
    /// Task { ... } block.
    @MainActor
    static func signIn(into app: AppState) async {
        #if os(iOS)
        guard let presenter = topViewController() else {
            AppLogger.app.error("google: no presenter view controller")
            app.errorMessage = String(localized: "onboarding.signin_failed")
            return
        }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else {
                AppLogger.app.error("google: no idToken in result")
                app.errorMessage = String(localized: "onboarding.signin_failed")
                return
            }
            await app.signInWithGoogle(idToken: idToken)
        } catch {
            // User cancel is not an error we surface.
            let ns = error as NSError
            if ns.code == GIDSignInError.canceled.rawValue { return }
            AppLogger.app.error("google: sign-in failed: \(String(describing: error), privacy: .public)")
            app.errorMessage = String(localized: "onboarding.signin_failed")
        }
        #else
        app.errorMessage = String(localized: "onboarding.signin_failed")
        #endif
    }

    #if os(iOS)
    private static func topViewController(base: UIViewController? = nil) -> UIViewController? {
        let root = base ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .rootViewController
        if let nav = root as? UINavigationController {
            return topViewController(base: nav.visibleViewController)
        }
        if let tab = root as? UITabBarController, let selected = tab.selectedViewController {
            return topViewController(base: selected)
        }
        if let presented = root?.presentedViewController {
            return topViewController(base: presented)
        }
        return root
    }
    #endif
}
