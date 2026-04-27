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
                    HStack(spacing: 8) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .accessibilityAddTraits(.updatesFrequently)
                        Button {
                            app.errorMessage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("error.dismiss", comment: "VoiceOver label for the error toast close button"))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.red.opacity(0.85), in: Capsule())
                    Spacer()
                }
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: error) {
                    // Auto-dismiss after 5 seconds. Cancelled if a new error
                    // replaces this one (the .task id changes), so the timer
                    // restarts cleanly per message.
                    try? await Task.sleep(for: .seconds(5))
                    if app.errorMessage == error {
                        app.errorMessage = nil
                    }
                }
            }

            // Recovery toast — softer styling than errorMessage (blue/info,
            // not red/alarm). Surfaces TrafficHealthMonitor fallback events.
            if let toast = app.fallbackToastMessage {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.white)
                        Text(toast)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .accessibilityAddTraits(.updatesFrequently)
                        Button {
                            app.fallbackToastMessage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.85), in: Capsule())
                    Spacer()
                }
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(for: .seconds(5))
                    if app.fallbackToastMessage == toast {
                        app.fallbackToastMessage = nil
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: app.errorMessage != nil)
        .animation(.easeInOut(duration: 0.3), value: app.fallbackToastMessage != nil)
        .onAppear {
            #if DEBUG
            cachedBuildInfoLine = computeBuildInfoLine()
            #else
            cachedBuildInfoLine = ""
            #endif
        }
        .sheet(isPresented: $showServers) {
            ServerListView().environment(app)
                .macSheetSize()
                .macCloseButton { showServers = false }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(app).environment(themeManager)
                .macSheetSize()
                .macCloseButton { showSettings = false }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallRouter().environment(app).environment(themeManager)
                .macSheetSize()
                .macCloseButton { showPaywall = false }
        }
        .sheet(isPresented: $showThemePicker) {
            ThemePickerView(isModal: true).environment(themeManager)
                .macSheetSize()
                .macCloseButton { showThemePicker = false }
        }
        .sheet(isPresented: Bindable(app).showPermissionPrimer) {
            VPNPermissionPrimerView {
                Task { await app.proceedAfterPrimer() }
            }
            .environment(themeManager)
            .macSheetSize()
        }
    }

    private func computeBuildInfoLine() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let cfgHash: String = {
            guard let config = app.configStore.loadConfig(),
                  let data = config.data(using: .utf8) else { return "?" }
            // Prefer the human-readable `_marker` field that the backend
            // stamps on every generated config (e.g. "40.2-chain-fix"). The
            // backend bumps this constant on any behavioural change to
            // clientconfig.go, so the user can tell at a glance which
            // version they have. Fall back to a 32-bit FNV-1a digest only
            // if the marker is missing (older configs / non-MadFrog JSON).
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let marker = json["_marker"] as? String, !marker.isEmpty {
                return marker
            }
            var hash: UInt64 = 14695981039346656037
            for byte in data {
                hash ^= UInt64(byte)
                hash = hash &* 1099511628211
            }
            return String(format: "%08x", UInt32(hash & 0xFFFFFFFF))
        }()
        return "v\(version)(\(build)) cfg:\(cfgHash)"
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
    /// Pretty country-level name for the home screen pill/chip.
    /// Build-32 UX: surface only the country, never the leaf protocol.
    /// Power-mode users see the leg as a subtitle (`currentLegName` below).
    static func selectedServerName(_ app: AppState) -> String {
        guard let tag = app.selectedServerTag else {
            return String(localized: "home.server.auto")
        }
        for group in app.servers {
            // Tag points at a country urltest directly: show its label.
            if let country = group.countries.first(where: { $0.tag == tag }) {
                return "\(country.flagEmoji) \(country.name)".trimmingCharacters(in: .whitespaces)
            }
            // Tag is a leaf: promote display to its containing country.
            if let country = group.countries.first(where: { $0.serverTags.contains(tag) }) {
                return "\(country.flagEmoji) \(country.name)".trimmingCharacters(in: .whitespaces)
            }
            // Selector tag itself.
            if group.tag == tag { return group.tag }
        }
        return tag
    }

    /// Live "current leg" for the selected country — reads the urltest pick
    /// from the command client's groups feed. Returns nil if the leg is
    /// the country itself (user hasn't pinned a specific protocol) or if
    /// the data isn't available yet. Used by power-mode subtitle and by
    /// TrafficHealthMonitor for fallback decisions.
    static func currentLegName(_ app: AppState) -> String? {
        let pinnedTag = app.selectedServerTag
        guard let group = app.servers.first(where: { $0.type == "selector" && $0.selectable }) else {
            return nil
        }
        // Country urltest tag the user is currently routed through. For Auto
        // (pinnedTag == nil) we follow Proxy's selected hop.
        let countryTag: String? = {
            if let pinned = pinnedTag,
               let _ = group.countries.first(where: { $0.tag == pinned }) {
                return pinned
            }
            if let pinned = pinnedTag,
               let country = group.countries.first(where: { $0.serverTags.contains(pinned) }) {
                return country.tag
            }
            return nil
        }()
        guard let countryTag else { return nil }
        // Live group state from libbox. Match by tag; use the urltest's
        // `selected` field which is the leaf currently picked by it.
        guard let live = app.commandClient.groups.first(where: { $0.tag == countryTag }),
              !live.selected.isEmpty
        else { return nil }
        if let leaf = live.items.first(where: { $0.tag == live.selected }) {
            return leaf.displayLabel
        }
        return nil
    }
}

// MARK: - Timer

struct TimerView: View {
    let since: Date
    let theme: Theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(formatted(at: context.date))
                .font(.system(.title2, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func formatted(at now: Date) -> String {
        let elapsed = Int(now.timeIntervalSince(since))
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Server List (shared)

struct ServerListView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// Number of taps on the nav title since the view appeared. Resets on
    /// dismiss. 5 consecutive taps unlock power mode (per-protocol leaves).
    @State private var titleTapCount = 0

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
        countryGroups.filter { $0.section == .whitelistBypass }
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
                            countryRowOrLink(for: country)
                        }
                    } header: {
                        Text(L10n.Servers.sectionDirect)
                    }
                }

                // Russia-exit relays (bypass regional blocks)
                if !relayGroups.isEmpty {
                    Section {
                        ForEach(relayGroups) { country in
                            countryRowOrLink(for: country)
                        }
                    } header: {
                        Text(L10n.Servers.sectionBypass)
                    } footer: {
                        Text(L10n.Servers.sectionBypassHint)
                    }
                }
            }
            .platformInsetGroupedList()
            .navigationTitle(Text(L10n.Servers.title))
            .iosInlineNavTitle()
            .onAppear {
                TunnelFileLogger.log("ServerListView: appeared, groups=\(app.servers.count), powerMode=\(app.powerModeUnlocked)", category: "ui")
                titleTapCount = 0
            }
            .onDisappear { TunnelFileLogger.log("ServerListView: disappeared", category: "ui") }
            .task {
                // One-shot probe on appear. Manual refresh available via the
                // ↻ toolbar button. Removing the periodic poll keeps the view
                // cheap (was hammering all servers every 30s).
                await app.pingService.probe(allServers)
            }
            .toolbar {
                // Invisible 5-tap target where the inline nav title renders.
                // The system-rendered title doesn't surface SwiftUI gestures,
                // so we put our own Text in the principal slot and count taps
                // there. 5 taps unlock power mode (per-protocol leaves) for
                // the rest of the session.
                ToolbarItem(placement: .principal) {
                    Text(L10n.Servers.title)
                        .font(.headline)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            titleTapCount += 1
                            if titleTapCount >= 5 && !app.powerModeUnlocked {
                                app.powerModeUnlocked = true
                                Haptics.notify(.success)
                                TunnelFileLogger.log("power mode: UNLOCKED via 5-tap on nav title", category: "ui")
                            }
                        }
                }
                ToolbarItem(placement: PlatformToolbarPlacement.trailing.resolved) {
                    Button(L10n.Servers.done) {
                        TunnelFileLogger.log("TAP: Done in server list", category: "ui")
                        dismiss()
                    }
                }
                ToolbarItem(placement: PlatformToolbarPlacement.leading.resolved) {
                    Button {
                        TunnelFileLogger.log("TAP: refresh config + pings", category: "ui")
                        Task {
                            await app.refreshConfig(timeout: .seconds(8))
                            if let group = selectorGroup {
                                app.commandClient.urlTest(groupTag: group.tag)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    /// Row for a country. Behaviour:
    ///   - Default mode (powerMode = false), direct section: tap pins the
    ///     country urltest tag and dismisses. The user never sees the leaf
    ///     submenu — like Mullvad/ProtonVPN/ExpressVPN. sing-box's urltest
    ///     auto-picks the best leg inside the country and TrafficHealthMonitor
    ///     promotes them off a dead leg if one stops responding.
    ///   - Power mode unlocked: multi-server countries drill into the leaf
    ///     picker so testers can pin a specific protocol.
    ///   - Whitelist-bypass section: always drills in (SPB relay endpoints
    ///     are intentionally exposed individually — they have very different
    ///     reachability profiles).
    ///   - Single-server country (only one leaf): always one-tap regardless
    ///     of mode — there's nothing to pick between.
    @ViewBuilder
    private func countryRowOrLink(for country: CountryGroup) -> some View {
        let serversInCountry = allServers.filter { country.serverTags.contains($0.tag) }
        let alwaysDrillIn = country.section == .whitelistBypass
        let singleServer = serversInCountry.count <= 1
        let showLeafPicker = alwaysDrillIn || (app.powerModeUnlocked && !singleServer)

        if showLeafPicker {
            NavigationLink {
                CountryServersView(country: country, servers: serversInCountry)
            } label: {
                CountryRow(country: country, selectedTag: app.selectedServerTag, pingService: app.pingService)
            }
        } else if singleServer, let only = serversInCountry.first {
            // Edge case: country with exactly one leaf — pin the leaf
            // itself; pinning the country urltest would still resolve to
            // the same outbound but is needlessly indirect.
            Button {
                TunnelFileLogger.log("TAP: country row (flat) '\(country.id)' → '\(only.tag)'", category: "ui")
                if let group = selectorGroup {
                    app.selectServer(groupTag: group.tag, serverTag: only.tag)
                }
                dismiss()
            } label: {
                CountryRow(country: country, selectedTag: app.selectedServerTag, pingService: app.pingService)
            }
            .buttonStyle(.plain)
        } else {
            // Default UX: one-tap country pin. Selects the country's
            // urltest tag (e.g. "🇩🇪 Германия"). sing-box urltest then
            // picks the best leg, and TrafficHealthMonitor escalates if
            // the country itself goes dark.
            Button {
                TunnelFileLogger.log("TAP: country row (urltest pin) '\(country.id)' → '\(country.tag)'", category: "ui")
                if let group = selectorGroup {
                    app.selectServer(groupTag: group.tag, serverTag: country.tag)
                }
                dismiss()
            } label: {
                CountryRow(country: country, selectedTag: app.selectedServerTag, pingService: app.pingService)
            }
            .buttonStyle(.plain)
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
                if app.selectedServerTag == nil {
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
        // Match either the country urltest tag itself (default-mode pin)
        // or any leaf tag inside the country (power-mode pin).
        return selectedTag == country.tag || country.serverTags.contains(selectedTag)
    }

    /// Best probed latency across this country's servers.
    /// Treat 0 and sub-2ms as "not measured yet" — sing-box's urltest reports
    /// a placeholder 1ms right after a selector switch, which looked like a
    /// bug to users ("Netherlands 1ms? impossible"). Show a skeleton until
    /// a real probe comes in.
    private var bestProbedMs: Int {
        let probed = country.serverTags.compactMap { tag -> Int? in
            let ms = pingService.latency(for: tag)
            return ms >= 2 ? ms : nil
        }
        if let best = probed.min() { return best }
        let fallback = Int(country.bestDelay)
        return fallback >= 2 ? fallback : 0
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(country.flagEmoji.isEmpty ? "🌍" : country.flagEmoji)
                .font(.system(size: 30))
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(country.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(country.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if bestProbedMs > 0 {
                PingBadge(ms: bestProbedMs)
            } else {
                PingSkeleton()
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
                            PingSkeleton()
                        }
                        if app.selectedServerTag == server.tag {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .platformInsetGroupedList()
        .navigationTitle(Text(verbatim: L10n.Servers.serversIn(country.name)))
        .iosInlineNavTitle()
        .task {
            await app.pingService.probe(servers)
        }
    }
}

/// Shimmering placeholder shown in place of PingBadge while a country/server
/// hasn't been probed yet. Same footprint as PingBadge so rows don't jump
/// when the real value lands.
private struct PingSkeleton: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = 0.5 * (1 + sin(t * 2 * .pi / 1.2))
            Capsule()
                .fill(Color.secondary.opacity(0.10 + 0.12 * phase))
                .frame(width: 44, height: 18)
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
