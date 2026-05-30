import SwiftUI
import Libbox
import UserNotifications

@main
struct MadFrogVPNApp: App {
    @State private var appState = AppState()
    @State private var themeManager = ThemeManager()
    @Environment(\.scenePhase) private var scenePhase

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
        TunnelFileLogger.logSync("=== APP LAUNCH (build 38d) base=\(AppConstants.sharedContainerURL.path) ===", category: "boot")

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
                } else {
                    OnboardingView()
                }
            }
            .environment(appState)
            .environment(themeManager)
            .task { await appState.initialize() }
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
final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// Singleton — `UNUserNotificationCenter.delegate` is `weak`, so storing
    /// it as a per-app `@State` would let ARC reap it before iOS routes a
    /// tap. The shared instance lives for the process lifetime.
    static let shared = AppNotificationDelegate()

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
            completionHandler([.banner, .sound])
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
