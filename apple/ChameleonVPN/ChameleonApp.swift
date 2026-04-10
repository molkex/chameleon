import SwiftUI

@main
struct ChameleonApp: App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.isAuthenticated {
                    MainView()
                } else {
                    OnboardingView()
                }
            }
            .environment(appState)
            .task { await appState.initialize() }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await appState.handleForeground() }
                }
            }
            .animation(.easeInOut(duration: 0.4), value: appState.isAuthenticated)
        }
    }
}
