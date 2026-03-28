import SwiftUI

struct TabRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: Tab = {
        if CommandLine.arguments.contains("-tab-servers") { return .servers }
        if CommandLine.arguments.contains("-tab-settings") { return .settings }
        return .home
    }()
    @State private var tabBounce: [Tab: Int] = [:]

    private let tabAnimation = Animation.spring(response: 0.35, dampingFraction: 0.85)

    enum Tab: String, CaseIterable {
        case home, servers, settings

        var icon: String {
            switch self {
            case .home: return "shield.checkered"
            case .servers: return "globe"
            case .settings: return "gearshape"
            }
        }

        var filledIcon: String {
            switch self {
            case .home: return "shield.fill"
            case .servers: return "globe.fill"
            case .settings: return "gearshape.fill"
            }
        }

        var title: String {
            switch self {
            case .home: return "VPN"
            case .servers: return "Серверы"
            case .settings: return "Настройки"
            }
        }
    }

    private var isDark: Bool { colorScheme == .dark }

    private var bgGradient: LinearGradient {
        LinearGradient(
            colors: isDark
                ? [Color(red: 0.08, green: 0.12, blue: 0.24),
                   Color(red: 0.05, green: 0.14, blue: 0.11)]
                : [Color(red: 0.93, green: 0.95, blue: 1.0),
                   Color(red: 0.89, green: 0.94, blue: 0.91)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            bgGradient
                .ignoresSafeArea()

            TabView(selection: $selectedTab) {
                HomeView()
                    .background { bgGradient.ignoresSafeArea() }
                    .tag(Tab.home)

                ServersView()
                    .background { bgGradient.ignoresSafeArea() }
                    .tag(Tab.servers)

                NavigationStack {
                    SettingsView()
                }
                .toolbarBackground(.clear, for: .navigationBar)
                .background { bgGradient.ignoresSafeArea() }
                .tag(Tab.settings)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(tabAnimation, value: selectedTab)
            .padding(.bottom, 76)
            .onAppear {
                UIScrollView.appearance().backgroundColor = .clear
                #if targetEnvironment(macCatalyst)
                UIScrollView.appearance().bounces = false
                #endif
            }

            customTabBar
        }
        .ignoresSafeArea(.keyboard)
        .onChange(of: selectedTab) { _, _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    // MARK: - Custom Tab Bar

    private var customTabBar: some View {
        GeometryReader { geo in
            let count = CGFloat(Tab.allCases.count)
            let tabW = geo.size.width / count
            let idx = CGFloat(Tab.allCases.firstIndex(of: selectedTab) ?? 0)

            ZStack(alignment: .leading) {
                // Capsule first — renders behind buttons so taps pass through
                Capsule()
                    .fill(Color.green.opacity(0.22))
                    .frame(width: tabW - 8, height: geo.size.height - 8)
                    .offset(x: idx * tabW + 4, y: 4)
                    .animation(tabAnimation, value: idx)
                    .allowsHitTesting(false)

                // Buttons on top — always receive taps
                HStack(spacing: 0) {
                    ForEach(Tab.allCases, id: \.rawValue) { tab in
                        tabButton(tab)
                    }
                }
            }
        }
        .frame(height: 60)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                )
                .shadow(color: .black.opacity(0.12), radius: 20, y: -2)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 2)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func tabButton(_ tab: Tab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            tabBounce[tab, default: 0] += 1
            withAnimation(tabAnimation) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isSelected ? tab.filledIcon : tab.icon)
                    .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
                    .symbolEffect(.bounce, value: tabBounce[tab, default: 0])
                Text(tab.title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color.green : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(tabAnimation, value: isSelected)
    }
}
