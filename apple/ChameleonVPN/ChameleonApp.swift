import SwiftUI
import Libbox

@main
struct ChameleonApp: App {
    @State private var appState = AppState()
    @State private var themeManager = ThemeManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
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
            TunnelFileLogger.log("ChameleonApp: LibboxSetup failed: \(err)", category: "ui")
        } else {
            TunnelFileLogger.log("ChameleonApp: LibboxSetup OK base=\(opts.basePath)", category: "ui")
        }
    }

    var body: some Scene {
        let window = WindowGroup {
            Group {
                if !appState.isInitialized {
                    Color.black.ignoresSafeArea()
                } else if !themeManager.hasSelected {
                    ThemePickerView()
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
                // Wire best-effort server sync: local is source of truth,
                // so errors are swallowed and the UI is never blocked.
                themeManager.remoteSync = { [weak appState] themeID in
                    guard let token = appState?.configStore.accessToken else { return }
                    Task.detached {
                        try? await appState?.apiClient.setTheme(themeID, accessToken: token)
                    }
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
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
                .defaultSize(width: 480, height: 900)
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
        guard path.hasPrefix("/app/payment/") else { return }
        TunnelFileLogger.log("ChameleonApp: universal link \(path)", category: "ui")
        NotificationCenter.default.post(
            name: .paymentReturnFromLink,
            object: nil,
            userInfo: ["url": url]
        )
    }
}

extension Notification.Name {
    static let paymentReturnFromLink = Notification.Name("madfrog.paymentReturnFromLink")
}

private extension View {
    /// On macOS (both native target and iOS-on-Mac runtime) enforce an
    /// iPhone-shaped minimum size so the layout never compresses below what
    /// the iOS views were designed for. iOS targets: no-op.
    @ViewBuilder
    func macWindowFrame() -> some View {
        #if os(macOS)
        self.frame(minWidth: 440, idealWidth: 480, minHeight: 820, idealHeight: 900)
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac {
            self.frame(minWidth: 440, idealWidth: 480, minHeight: 820, idealHeight: 900)
        } else {
            self
        }
        #endif
    }
}
