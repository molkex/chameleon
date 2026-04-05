import SwiftUI

@main
struct ChameleonApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(appState)
                .task { await appState.initialize() }
        }
    }
}
