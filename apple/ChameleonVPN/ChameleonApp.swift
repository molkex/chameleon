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
        WindowGroup {
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
            .animation(.easeInOut(duration: 0.3), value: appState.isInitialized)
            .animation(.easeInOut(duration: 0.4), value: appState.isAuthenticated)
        }
    }
}
