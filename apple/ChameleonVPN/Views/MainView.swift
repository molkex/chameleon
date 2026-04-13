import SwiftUI
import NetworkExtension

/// Dispatcher: picks the layout that matches the currently selected theme.
/// Each variant is a completely separate composition (layout, typography,
/// geometry) — not just a recolor of the same structure.
struct MainView: View {
    @Environment(AppState.self) private var app
    @Environment(ThemeManager.self) private var themeManager

    @State private var showServers = false
    @State private var showSettings = false
    @State private var showPaywall = false
    @State private var showThemePicker = false
    @State private var cachedBuildInfoLine: String = ""

    var body: some View {
        ZStack {
            switch themeManager.current.id {
            case "neon":
                MainViewNeon(
                    app: app,
                    showServers: $showServers,
                    showSettings: $showSettings,
                    showPaywall: $showPaywall,
                    cachedBuildInfoLine: cachedBuildInfoLine
                )
            default:
                MainViewCalm(
                    app: app,
                    showServers: $showServers,
                    showSettings: $showSettings,
                    showPaywall: $showPaywall,
                    cachedBuildInfoLine: cachedBuildInfoLine
                )
            }

            if let error = app.errorMessage {
                VStack {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.red.opacity(0.85), in: Capsule())
                        .onTapGesture { app.errorMessage = nil }
                    Spacer()
                }
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: app.errorMessage != nil)
        .onAppear { cachedBuildInfoLine = computeBuildInfoLine() }
        .sheet(isPresented: $showServers) {
            ServerListView().environment(app)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(app).environment(themeManager)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environment(app).environment(themeManager)
        }
        .sheet(isPresented: $showThemePicker) {
            ThemePickerView(isModal: true).environment(themeManager)
        }
    }

    private func computeBuildInfoLine() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let sni: String = {
            guard let config = app.configStore.loadConfig(),
                  let data = config.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let outbounds = json["outbounds"] as? [[String: Any]] else { return "?" }
            for ob in outbounds {
                if let tls = ob["tls"] as? [String: Any],
                   let serverName = tls["server_name"] as? String {
                    return serverName
                }
            }
            return "?"
        }()
        return "v\(version)(\(build)) sni:\(sni)"
    }
}

// MARK: - Shared helpers (used by both Calm and Neon variants)

/// High-level connection state for the UI. Collapses the 6 NEVPNStatus
/// values (plus "no permission yet") into 6 buckets the UI actually needs
/// to render distinct states for.
enum ConnectionState: Equatable {
    case disconnected        // idle, ready to connect
    case connecting          // tunnel coming up, first attempt
    case connected           // fully up, traffic flowing
    case reconnecting        // network changed (Wi-Fi↔LTE), tunnel re-establishing
    case disconnecting       // user tapped disconnect, tearing down
    case permissionDenied    // NEVPN profile in .invalid state (user refused)

    /// True when the UI should show a busy indicator (no user input accepted).
    var isBusy: Bool {
        switch self {
        case .connecting, .reconnecting, .disconnecting: return true
        default: return false
        }
    }

    /// True when the VPN is actually protecting traffic right now.
    var isProtected: Bool { self == .connected }
}

@MainActor
enum VPNStateHelper {
    static func state(_ app: AppState) -> ConnectionState {
        switch app.vpnManager.status {
        case .connected: return .connected
        case .connecting: return .connecting
        case .reasserting: return .reconnecting
        case .disconnecting: return .disconnecting
        case .invalid: return .permissionDenied
        case .disconnected: return .disconnected
        @unknown default: return .disconnected
        }
    }

    static func isConnected(_ app: AppState) -> Bool {
        state(app) == .connected
    }
    static func isConnecting(_ app: AppState) -> Bool {
        let s = state(app)
        return s == .connecting || s == .reconnecting
    }
    static func selectedServerName(_ app: AppState) -> String {
        if let tag = app.configStore.selectedServerTag {
            for group in app.servers {
                if let item = group.items.first(where: { $0.tag == tag }) {
                    return item.tag
                }
                if group.tag == tag { return group.tag }
            }
            return tag
        }
        return String(localized: "home.server.auto")
    }
}

// MARK: - Timer

struct TimerView: View {
    let since: Date
    let theme: Theme
    @State private var elapsed: TimeInterval = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(formatted)
            .font(.system(.title2, design: .monospaced))
            .foregroundStyle(theme.textSecondary)
            .onReceive(timer) { _ in
                elapsed = Date().timeIntervalSince(since)
            }
    }

    private var formatted: String {
        let h = Int(elapsed) / 3600
        let m = (Int(elapsed) % 3600) / 60
        let s = Int(elapsed) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Server List (shared)

struct ServerListView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var selectorGroup: ServerGroup? {
        app.servers.first { $0.type == "selector" && $0.selectable }
    }

    private var countryGroups: [CountryGroup] {
        selectorGroup?.countryGroups ?? []
    }

    private var directGroups: [CountryGroup] {
        countryGroups.filter { $0.section == .direct && $0.id != "other" }
    }

    private var relayGroups: [CountryGroup] {
        countryGroups.filter { $0.section == .relay }
    }

    private var allServers: [ServerItem] {
        selectorGroup?.items ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                // Auto pick row
                Section {
                    autoRow
                }

                // Direct countries
                if !directGroups.isEmpty {
                    Section {
                        ForEach(directGroups) { country in
                            NavigationLink {
                                CountryServersView(
                                    country: country,
                                    servers: allServers.filter { $0.countryKey == country.id }
                                )
                            } label: {
                                CountryRow(country: country, selectedTag: app.configStore.selectedServerTag, pingService: app.pingService)
                            }
                        }
                    } header: {
                        Text("Прямые подключения")
                    }
                }

                // Russia-exit relays (bypass regional blocks)
                if !relayGroups.isEmpty {
                    Section {
                        ForEach(relayGroups) { country in
                            NavigationLink {
                                CountryServersView(
                                    country: country,
                                    servers: allServers.filter { $0.countryKey == country.id }
                                )
                            } label: {
                                CountryRow(country: country, selectedTag: app.configStore.selectedServerTag, pingService: app.pingService)
                            }
                        }
                    } header: {
                        Text("Обход блокировок")
                    } footer: {
                        Text("Подключение через российский сервер в зарубежные узлы — для обхода блокировок провайдеров.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Text(L10n.Servers.title))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { TunnelFileLogger.log("ServerListView: appeared, groups=\(app.servers.count)", category: "ui") }
            .onDisappear { TunnelFileLogger.log("ServerListView: disappeared", category: "ui") }
            .task {
                // Initial probe + periodic refresh while the screen is open.
                // SwiftUI cancels this task when the view goes away.
                await app.pingService.probe(allServers)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    if Task.isCancelled { break }
                    await app.pingService.probe(allServers)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Servers.done) {
                        TunnelFileLogger.log("TAP: Done in server list", category: "ui")
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        TunnelFileLogger.log("TAP: refresh pings", category: "ui")
                        if let group = selectorGroup {
                            app.commandClient.urlTest(groupTag: group.tag)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var autoRow: some View {
        Button {
            TunnelFileLogger.log("TAP: server row 'Auto'", category: "ui")
            if let group = selectorGroup {
                app.selectServer(groupTag: group.tag, serverTag: "Auto")
            }
            dismiss()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.Servers.autoBest)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(L10n.Home.autoLongName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if app.configStore.selectedServerTag == nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CountryRow: View {
    let country: CountryGroup
    let selectedTag: String?
    let pingService: PingService

    private var isSelected: Bool {
        guard let selectedTag else { return false }
        return country.serverTags.contains(selectedTag)
    }

    /// Best probed latency across this country's servers (0 = not yet measured).
    private var bestProbedMs: Int {
        let probed = country.serverTags.compactMap { tag -> Int? in
            let ms = pingService.latency(for: tag)
            return ms > 0 ? ms : nil
        }
        if let best = probed.min() { return best }
        return Int(country.bestDelay)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(country.flagEmoji.isEmpty ? "🌍" : country.flagEmoji)
                .font(.system(size: 30))
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Servers.countryName(country.id))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(country.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if bestProbedMs > 0 {
                PingBadge(ms: bestProbedMs)
            }

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

private struct CountryServersView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let country: CountryGroup
    let servers: [ServerItem]

    private func ping(_ server: ServerItem) -> Int {
        // Prefer out-of-band TCP probe; fall back to sing-box urltest delay.
        let probed = app.pingService.latency(for: server.tag)
        if probed > 0 { return probed }
        return Int(server.delay)
    }

    private var sortedServers: [ServerItem] {
        servers.sorted { lhs, rhs in
            let ld = ping(lhs)
            let rd = ping(rhs)
            let lval = ld <= 0 ? Int.max : ld
            let rval = rd <= 0 ? Int.max : rd
            return lval < rval
        }
    }

    var body: some View {
        List {
            ForEach(sortedServers, id: \.tag) { server in
                Button {
                    TunnelFileLogger.log("TAP: server row '\(server.tag)'", category: "ui")
                    if let group = app.servers.first(where: { $0.type == "selector" && $0.selectable }) {
                        app.selectServer(groupTag: group.tag, serverTag: server.tag)
                    }
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: server.isHysteria ? "bolt.horizontal.fill" : "network")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.displayLabel)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        let ms = ping(server)
                        if ms > 0 {
                            PingBadge(ms: ms)
                        } else {
                            Text(L10n.Servers.pingUnknown)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if app.configStore.selectedServerTag == server.tag {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(verbatim: L10n.Servers.serversIn(L10n.Servers.countryName(country.id))))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await app.pingService.probe(servers)
        }
    }
}

private struct PingBadge: View {
    let ms: Int

    private var color: Color {
        switch ms {
        case ..<80:   return .green
        case ..<180:  return .yellow
        default:      return .orange
        }
    }

    var body: some View {
        Text(L10n.Servers.pingMs(ms))
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}
