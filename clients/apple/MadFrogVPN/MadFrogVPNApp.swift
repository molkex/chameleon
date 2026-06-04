import SwiftUI
import Libbox
import UserNotifications
#if os(iOS)
import UIKit
#endif

@main
struct MadFrogVPNApp: App {
    @State private var appState = AppState()
    @State private var themeManager = ThemeManager()
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    // SUPPORT-CHAT P4 — owns the UIApplicationDelegate callbacks for APNs
    // device-token delivery and support-reply taps. The delegate is the same
    // process-lifetime singleton used for LAUNCH-08 (UNUserNotificationCenter
    // delegate), so the adaptor just hands SwiftUI the shared instance.
    @UIApplicationDelegateAdaptor(AppNotificationDelegate.self) private var appDelegate
    #endif

    init() {
        // LAUNCH-03: bring up Sentry FIRST so a crash in any of the
        // initialisers below is still captured. No-op when SENTRY_DSN
        // Info.plist key is empty (dev / open-source clones) — see
        // CrashReporter.swift for the strict-privacy posture.
        CrashReporter.start()

        // Sync boot marker — proves TunnelFileLogger is writing to disk.
        // logSync ensures the line is on disk before init returns; if the
        // log file is empty after a launch we can rule out "missing call
        // site" and look at file system / entitlement issues.
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        TunnelFileLogger.logSync("=== APP LAUNCH (build \(build)) base=\(AppConstants.sharedContainerURL.path) ===", category: "boot")

        // Libbox needs basePath set so LibboxNewCommandClient can find
        // command.sock created by the extension's CommandServer.
        // MUST match paths used in ExtensionProvider.startSingBox().
        let opts = LibboxSetupOptions()
        opts.basePath = AppConstants.sharedContainerURL.path
        opts.workingPath = AppConstants.workingDirectory.path
        opts.tempPath = AppConstants.tempDirectory.path
        opts.debug = false
        var err: NSError?
        LibboxSetup(opts, &err)
        if let err {
            TunnelFileLogger.logSync("MadFrogVPNApp: LibboxSetup failed: \(err)", category: "ui")
        } else {
            TunnelFileLogger.logSync("MadFrogVPNApp: LibboxSetup OK base=\(opts.basePath)", category: "ui")
        }

        // LAUNCH-08: claim the notification center delegate slot before any
        // notification request lands. iOS routes "Reconnect" taps through
        // this delegate; without it our action button would just open the
        // app with no follow-through.
        UNUserNotificationCenter.current().delegate = AppNotificationDelegate.shared
    }

    var body: some Scene {
        let window = WindowGroup {
            Group {
                if !appState.isInitialized {
                    Color.black.ignoresSafeArea()
                } else if appState.isAuthenticated {
                    MainView()
                        // SUPPORT-CHAT P4: a tapped "support reply" push flips
                        // `pendingSupportChatOpen`; present the chat from the app
                        // root so it opens regardless of which screen is on top.
                        // Reset the flag on dismiss. SwiftUI propagates the
                        // .environment objects below into the sheet, but inject
                        // them explicitly so SupportChatView always has app +
                        // themeManager even when presented from the root.
                        .sheet(isPresented: Bindable(appState).pendingSupportChatOpen) {
                            SupportChatView()
                                .environment(appState)
                                .environment(themeManager)
                        }
                        // INAPP-ANNOUNCEMENTS: a centered, dismissible card over
                        // the home when there's an active announcement.
                        .overlay {
                            if let announcement = appState.activeAnnouncement {
                                AnnouncementView(announcement: announcement)
                                    .environment(appState)
                                    .environment(themeManager)
                                    .zIndex(1)
                            }
                        }
                        .animation(.snappy(duration: 0.28), value: appState.activeAnnouncement)
                } else {
                    OnboardingView()
                }
            }
            .environment(appState)
            .environment(themeManager)
            .task { await appState.initialize() }
            .task(id: appState.isAuthenticated) {
                // Fetch the active announcement once the user is authenticated
                // (cold launch). Re-foreground is handled by the scenePhase hook.
                if appState.isAuthenticated { await appState.loadActiveAnnouncement() }
            }
            .task {
                // Clear any leftover app-icon badge on cold launch (a support push
                // set badge:1 while the app was closed). scenePhase covers re-foreground.
                try? await UNUserNotificationCenter.current().setBadgeCount(0)
            }
            .task {
                // SUPPORT-CHAT P4: wire the live AppState into the notification
                // delegate so APNs token delivery + support-reply taps can reach
                // it. The delegate is a process-lifetime singleton; the link is
                // weak so it never outlives AppState's natural scope.
                #if os(iOS)
                appDelegate.appState = appState
                #else
                AppNotificationDelegate.shared.appState = appState
                #endif
            }
            .task {
                // LAUNCH-08: register the notification category once so the
                // disconnect alert lands with a "Reconnect" action button.
                // Idempotent; safe to re-run on every launch.
                appState.disconnectNotifier.registerCategory()
            }
            .task {
                // Wire best-effort server sync: local is source of truth,
                // so errors are swallowed and the UI is never blocked.
                themeManager.remoteSync = { [weak appState] themeID in
                    guard let token = appState?.configStore.accessToken else { return }
                    Task.detached {
                        try? await appState?.apiClient.setTheme(themeID, accessToken: token)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .vpnReconnectRequested)) { _ in
                // LAUNCH-08: action button → AppNotificationDelegate posted
                // a Darwin-free NotificationCenter event. Re-enter via
                // toggleVPN() so the same single-flight guard + preflight
                // probe a manual tap goes through is honoured.
                Task { @MainActor in
                    appState.disconnectNotifier.dismissDelivered()
                    if !appState.vpnManager.isConnected {
                        await appState.toggleVPN()
                    }
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                let isActive = (newPhase == .active)
                appState.handleScenePhaseActive(isActive)
                Task { await appState.handleScenePhaseChange(active: isActive) }
                if isActive {
                    Task { await appState.handleForeground() }
                    Task { await appState.loadActiveAnnouncement() } // INAPP-ANNOUNCEMENTS
                    // A support-reply push sets the app-icon badge to 1; clear it
                    // when the user opens the app (it has no in-app meaning once seen).
                    Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
                }
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let url = activity.webpageURL else { return }
                handleUniversalLink(url)
            }
            .onOpenURL { url in
                handleUniversalLink(url)
            }
            .animation(.easeInOut(duration: 0.3), value: appState.isInitialized)
            .animation(.easeInOut(duration: 0.4), value: appState.isAuthenticated)
            .macWindowFrame()
        }
        #if os(macOS)
        return Group {
            window
                .defaultSize(width: 440, height: 760)
                .windowResizability(.contentMinSize)

            MenuBarExtra {
                MenuBarContent()
                    .environment(appState)
            } label: {
                Image(systemName: menuBarIconName)
            }
            .menuBarExtraStyle(.window)
        }
        #else
        return window
        #endif
    }

    #if os(macOS)
    /// Tray icon reflects VPN status at a glance — green shield when
    /// connected, grey slashed shield otherwise.
    private var menuBarIconName: String {
        VPNStateHelper.isConnected(appState) ? "checkmark.shield.fill" : "shield.slash"
    }
    #endif

    private func handleUniversalLink(_ url: URL) {
        guard url.host == "madfrog.online" else { return }
        let path = url.path
        TunnelFileLogger.log("MadFrogVPNApp: universal link \(path)", category: "ui")

        if path.hasPrefix("/app/payment/") {
            NotificationCenter.default.post(
                name: .paymentReturnFromLink,
                object: nil,
                userInfo: ["url": url]
            )
            return
        }

        if path == "/app/signin" {
            // Magic-link sign-in. Extract token and hand off to AppState
            // which will call /auth/magic/verify and authenticate the user.
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let token = comps.queryItems?.first(where: { $0.name == "token" })?.value,
                  !token.isEmpty else {
                TunnelFileLogger.log("magic link: missing token", category: "ui")
                return
            }
            Task { await appState.consumeMagicToken(token) }
            return
        }
    }
}

extension Notification.Name {
    static let paymentReturnFromLink = Notification.Name("madfrog.paymentReturnFromLink")
    /// LAUNCH-08 — posted by `AppNotificationDelegate` when the user taps
    /// the "Reconnect" action on the disconnect banner. The SwiftUI scene
    /// listens via `.onReceive(...)` and calls `AppState.toggleVPN()`.
    static let vpnReconnectRequested = Notification.Name("madfrog.vpnReconnectRequested")
}

/// LAUNCH-08 — `UNUserNotificationCenterDelegate` for the main app. iOS
/// invokes `didReceive` when the user taps the disconnect banner or its
/// "Reconnect" action. We forward to a `NotificationCenter` event so the
/// SwiftUI scene (which owns `AppState`) can drive the actual reconnect on
/// the MainActor — the delegate itself runs on a background queue by default,
/// and we don't want to capture the AppState reference here.
///
/// SUPPORT-CHAT P4 — this same delegate also serves as the
/// `UIApplicationDelegate` (registered via `@UIApplicationDelegateAdaptor` on
/// the App struct) so it can receive the APNs device token and route a tapped
/// "support reply" push into the app. The App struct injects a weak `AppState`
/// reference (`appState`) once the scene is up; the delegate forwards the token
/// to `AppState.handlePushToken` and a support-reply tap to
/// `AppState.handleSupportPushTap`.
final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// Singleton — `UNUserNotificationCenter.delegate` is `weak`, so storing
    /// it as a per-app `@State` would let ARC reap it before iOS routes a
    /// tap. The shared instance lives for the process lifetime.
    static let shared = AppNotificationDelegate()

    /// SUPPORT-CHAT P4 — weak link to the live AppState, injected by the App
    /// struct once the scene appears (on iOS into the `@UIApplicationDelegateAdaptor`
    /// instance, on macOS into `.shared`). Weak so the delegate (process-lifetime
    /// singleton) never keeps AppState alive past its natural scope. Used to
    /// forward the APNs device token and a tapped support-reply push.
    weak var appState: AppState?

    override init() {
        super.init()
    }

    /// Foreground delivery: if the user happens to be looking at the app
    /// while a notification fires, prefer NOT showing the OS banner — the
    /// in-app UI already reflects the disconnected state and a banner is
    /// redundant. `DisconnectNotifier.record(...)` also gates on
    /// `isAppActive` and shouldn't schedule when foreground, so this is a
    /// belt-and-braces guard for the race where a status update arrives
    /// after a background→foreground transition.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        let id = notification.request.identifier
        if id == AppConstants.disconnectNotificationID {
            completionHandler([])
        } else {
            // SUPPORT-CHAT P4: a support-reply push that arrives in the
            // foreground still shows a banner so the user notices the reply.
            completionHandler([.banner, .sound, .badge])
        }
    }

    /// Tap handler. For the disconnect notification: if the user tapped the
    /// "Reconnect" action OR the body of the banner (defaultActionIdentifier
    /// — implicit "open the app"), we kick off a reconnect via the
    /// NotificationCenter relay. Other identifiers are ignored.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        defer { completionHandler() }

        // SUPPORT-CHAT P4: a tapped "support reply" push opens the in-app chat.
        // The custom payload carries `{"type":"support_reply", ...}` alongside
        // the standard aps alert. Route to AppState on the MainActor.
        let userInfo = response.notification.request.content.userInfo
        if userInfo["type"] as? String == "support_reply" {
            let state = appState
            Task { @MainActor in state?.handleSupportPushTap() }
            return
        }

        let id = response.notification.request.identifier
        guard id == AppConstants.disconnectNotificationID else { return }

        let actionID = response.actionIdentifier
        let shouldReconnect =
            actionID == AppConstants.disconnectNotificationReconnectActionID ||
            actionID == UNNotificationDefaultActionIdentifier
        guard shouldReconnect else { return }

        // Cross the process-affinity boundary via NotificationCenter — the
        // SwiftUI scene observer picks this up on the MainActor.
        NotificationCenter.default.post(name: .vpnReconnectRequested, object: nil)
    }
}

// SUPPORT-CHAT P4 — iOS-only `UIApplicationDelegate` conformance. Registered on
// the App struct via `@UIApplicationDelegateAdaptor`, this gives us the APNs
// device-token + remote-notification-registration callbacks. macOS keeps the
// minimal UNUserNotificationCenter delegate above (no remote-push wiring yet),
// though the aps-environment entitlement is present on both platforms.
#if os(iOS)
extension AppNotificationDelegate: UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Claim the notification-center delegate slot as early as possible so a
        // tap that cold-started the app (launched from a push) still routes here.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        TunnelFileLogger.log("APNs: didRegister token len=\(deviceToken.count)", category: "push")
        let state = appState
        Task { await state?.handlePushToken(deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        TunnelFileLogger.log("APNs: didFailToRegister: \(error.localizedDescription)", category: "push")
    }
}
#endif

private extension View {
    /// On macOS (both native target and iOS-on-Mac runtime) enforce an
    /// iPhone-shaped minimum size so the layout never compresses below what
    /// the iOS views were designed for. iOS targets: no-op.
    @ViewBuilder
    func macWindowFrame() -> some View {
        #if os(macOS)
        self.frame(minWidth: 400, idealWidth: 440, minHeight: 560, idealHeight: 760)
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac {
            self.frame(minWidth: 400, idealWidth: 440, minHeight: 560, idealHeight: 760)
        } else {
            self
        }
        #endif
    }
}
