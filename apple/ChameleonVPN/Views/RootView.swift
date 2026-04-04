import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(AppConstants.onboardingCompletedKey) private var onboardingDone = false

    var body: some View {
        Group {
            #if targetEnvironment(simulator)
            TabRootView()
            #else
            if !onboardingDone {
                OnboardingView {
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                        onboardingDone = true
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else if appState.isActivated {
                TabRootView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                ActivationView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            #endif
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: onboardingDone)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: appState.isActivated)
        .task {
            await appState.initialize()
        }
    }
}
