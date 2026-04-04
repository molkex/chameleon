import SwiftUI

struct ServersView: View {
    @Environment(AppState.self) private var appState
    private var stats: CommandClientWrapper { appState.commandClient }
    private var vpn: VPNManager { appState.vpnManager }
    private var pinger: PingService { appState.pingService }
    @State private var isPinging = false
    @State private var expandedCountries: Set<String> = []
    /// Tag of the server row currently being applied via gRPC (shows spinner for ~0.8s)
    @State private var switchingTag: String? = nil

    /// When VPN is connected, use live gRPC data; otherwise, use config-parsed servers.
    private var isLive: Bool { vpn.isConnected && !stats.groups.isEmpty }

    private var groups: [ServerGroup] {
        isLive ? stats.groups : appState.configServers
    }

    /// Server selector group — a selector that contains urltest items.
    private var serverSelectorGroup: ServerGroup? {
        groups.first { $0.type == "selector" && $0.items.contains { $0.type == "urltest" } }
    }

    /// The tag of the individual server currently routing traffic.
    ///
    /// Live: resolves selector → urltest → selected outbound.
    /// Offline: the saved user preference (or "").
    /// Optimistic: if user saved a specific server preference that exists in a urltest group,
    /// show it immediately without waiting for gRPC groups refresh.
    private var effectiveActiveServerTag: String {
        // Optimistic: if user saved a specific server preference, use it right away.
        // Only applies to actual proxy server tags (not urltest/selector group tags).
        if let saved = appState.selectedServerTag, !saved.isEmpty {
            let isRealServer = groups.contains { grp in
                grp.type == "urltest" && grp.items.contains { $0.tag == saved }
            }
            if isRealServer { return saved }
        }

        if isLive {
            // Resolve: 🎯 Сервер → (selected urltest group or direct server)
            if let sel = serverSelectorGroup {
                let selectedTag = sel.selected
                // Selector points to a urltest group — resolve to that group's auto-selected server
                if let urltest = groups.first(where: { $0.tag == selectedTag && $0.type == "urltest" }) {
                    return urltest.selected
                }
                // Selector points directly to an individual server (new config format)
                return selectedTag
            }
        }
        // Offline: use explicitly saved preference
        return appState.selectedServerTag ?? ""
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.clear

                if groups.isEmpty {
                    emptyState
                } else {
                    serverList
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.clear, for: .navigationBar)
            .onAppear {
                // Auto-ping on first open if offline and no results yet
                if !isLive && !pinger.isPinging && pinger.results.isEmpty {
                    isPinging = true
                    pinger.pingAll(groups: appState.configServers)
                }
            }
            .onChange(of: pinger.isPinging) { _, newValue in
                if !newValue && isPinging && !isLive {
                    withAnimation { isPinging = false }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let autoGroup = groups.first(where: { $0.type == "urltest" }) {
                        HStack(spacing: 12) {
                            // Ping button (works in both online and offline modes)
                            Button {
                                let impact = UIImpactFeedbackGenerator(style: .light)
                                impact.impactOccurred()
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                    isPinging = true
                                }
                                if isLive {
                                    stats.urlTest(groupTag: autoGroup.tag)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        withAnimation { isPinging = false }
                                    }
                                } else {
                                    pinger.pingAll(groups: groups)
                                }
                            } label: {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.green)
                                    .symbolEffect(.variableColor.iterative, isActive: isPinging || pinger.isPinging)
                            }
                            .accessibilityLabel("Проверить пинг серверов")
                            .keyboardShortcut("r", modifiers: .command)
                            .disabled(isPinging || pinger.isPinging)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        let isActivated = appState.configStore.isActivated
        return VStack(spacing: 20) {
            HStack {
                Text("Серверы")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .padding(.leading, 16)
                Spacer()
            }
            .frame(maxWidth: .infinity)

            Spacer()

            Image(systemName: isActivated ? "exclamationmark.triangle" : "globe.desk")
                .font(.system(size: 56))
                .foregroundStyle(isActivated ? Color.orange.opacity(0.7) : Color.secondary.opacity(0.5))
                .symbolEffect(.pulse, options: .repeating, isActive: !isActivated)

            VStack(spacing: 8) {
                Text(isActivated ? "Не удалось загрузить серверы" : "Нет серверов")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(isActivated
                     ? "Обновите конфигурацию в Настройках"
                     : "Активируйте VPN чтобы\nувидеть список серверов")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    // MARK: - Server List

    private var serverList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                HStack {
                    Text("Серверы")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.primary)
                        .padding(.leading, 16)
                        .padding(.top, 4)
                    Spacer()
                }

                if let autoGroup = groups.first(where: { $0.type == "urltest" }) {
                    let countryGroups = autoGroup.countryGroups

                    // Auto card (urltest picks best)
                    autoCard(group: autoGroup)
                        .padding(.horizontal, 16)

                    // Country cards
                    ForEach(countryGroups) { country in
                        countryCard(country: country, group: autoGroup)
                            .padding(.horizontal, 16)
                    }
                }

                // Selector/routing section hidden — confuses users
            }
            .padding(.vertical, 8)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            isPinging = true
            if isLive, let autoGroup = groups.first(where: { $0.type == "urltest" }) {
                stats.urlTest(groupTag: autoGroup.tag)
                try? await Task.sleep(for: .seconds(2))
            } else {
                pinger.pingAll(groups: groups)
                // Wait for pinger to finish
                while pinger.isPinging {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            isPinging = false
        }
    }

    // MARK: - Auto Card

    private func autoCard(group: ServerGroup) -> some View {
        let isSelected = appState.selectedServerTag == nil

        return Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            if isLive {
                if let selectorGroup = serverSelectorGroup {
                    // Select the auto urltest group (first item in selector)
                    let autoItemTag = selectorGroup.items.first?.tag ?? ""
                    stats.selectOutbound(groupTag: selectorGroup.tag, outboundTag: autoItemTag)
                } else {
                    // Old config fallback: reset urltest (empty = auto)
                    stats.selectOutbound(groupTag: group.tag, outboundTag: "")
                }
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                appState.selectPreferredServer(tag: nil)
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.green.opacity(0.1))
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.green)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Авто")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("Лучший сервер по пингу")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                        .symbolEffect(.bounce, value: isSelected)
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color.green.opacity(0.06) : Color(.secondarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.green.opacity(0.3) : Color.clear,
                                lineWidth: 1
                            )
                    )
            }
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isSelected)
    }

    // MARK: - Country Card

    private func countryCard(country: CountryGroup, group: ServerGroup) -> some View {
        let savedTag = appState.selectedServerTag ?? ""
        let savedCountryKey = countryKeyFromTag(savedTag)
        let isSelected = country.serverTags.contains(savedTag) || savedCountryKey == country.id
        let isExpanded = expandedCountries.contains(country.id)
        let countryServers = group.items.filter {
            $0.countryKey == country.id &&
            $0.countryKey != "cdn" &&
            ($0.type == "vless" || $0.type == "hysteria2" || $0.type == "wireguard")
        }

        return VStack(spacing: 0) {
            countryCardHeader(country: country, group: group, isSelected: isSelected, isExpanded: isExpanded)

            // ── Expanded server list ──────────────────────────────────────────
            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)
                    .opacity(0.5)

                VStack(spacing: 0) {
                    ForEach(Array(countryServers.enumerated()), id: \.element.id) { index, server in
                        serverDetailRow(server: server, index: index + 1, activeTag: effectiveActiveServerTag)
                    }
                }
                .padding(.vertical, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? Color.green.opacity(0.06) : Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.green.opacity(0.3) : Color.clear,
                            lineWidth: 1
                        )
                )
        }
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        .contextMenu {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    _ = expandedCountries.insert(country.id)
                }
            } label: {
                Label("Показать серверы", systemImage: "list.bullet")
            }
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    if isExpanded { expandedCountries.remove(country.id) }
                    else { _ = expandedCountries.insert(country.id) }
                }
            } label: {
                Label(isExpanded ? "Свернуть" : "Развернуть",
                      systemImage: isExpanded ? "chevron.up" : "chevron.down")
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isExpanded)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isSelected)
    }

    // Extracted header to keep countryCard type-checkable
    @ViewBuilder
    private func countryCardHeader(country: CountryGroup, group: ServerGroup,
                                   isSelected: Bool, isExpanded: Bool) -> some View {
        HStack(spacing: 14) {
            ZStack {
                flagBackground(for: country.id)
                Color.black.opacity(0.12)
                Text(country.countryCode)
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(country.name))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(country.serverCount) \(StringUtils.serverNoun(country.serverCount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let pingInfo = bestPingForCountry(country) {
                let color = bestPingColor(pingInfo)
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 10, height: 10)
                        .shadow(color: color.opacity(0.6), radius: 4)
                    Text("\(pingInfo) ms")
                        .font(.caption.monospaced().weight(.medium))
                        .foregroundStyle(color)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(color.opacity(0.1), in: Capsule())
            }

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
                    .symbolEffect(.bounce, value: isSelected)
            }

            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary.opacity(0.7))
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .frame(width: 20)
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture { handleCountryTap(country: country, group: group, isExpanded: isExpanded) }
        .simultaneousGesture(TapGesture().onEnded { })
        .overlay(alignment: .trailing) {
            Color.clear.frame(width: 36).contentShape(Rectangle())
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        if expandedCountries.contains(country.id) { expandedCountries.remove(country.id) }
                        else { _ = expandedCountries.insert(country.id) }
                    }
                }
        }
    }

    private func handleCountryTap(country: CountryGroup, group: ServerGroup, isExpanded: Bool) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Country header tap = expand/collapse only.
        // Server selection happens only via explicit server row tap.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if isExpanded { expandedCountries.remove(country.id) }
            else { _ = expandedCountries.insert(country.id) }
        }
    }

    // MARK: - Server Detail Row (inside expanded country)

    private func serverDetailRow(server: ServerItem, index: Int, activeTag: String) -> some View {
        let isActive = server.tag == activeTag
        let isSwitching = switchingTag == server.tag
        let delay = isLive ? (server.delay > 0 ? server.delay : nil)
                           : (pinger.results[server.tag].flatMap { $0 > 0 ? $0 : nil })

        return HStack(spacing: 10) {
            // Active indicator / switching spinner
            ZStack {
                if isSwitching {
                    ProgressView()
                        .scaleEffect(0.55)
                        .tint(.green)
                } else {
                    Circle()
                        .fill(isActive ? Color.green : Color.clear)
                        .overlay(Circle().stroke(isActive ? Color.green : Color(.systemGray4), lineWidth: 1))
                }
            }
            .frame(width: 14, height: 14)

            Text(server.displayLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(isActive || isSwitching ? .primary : .secondary)

            Spacer()

            // Ping
            if let ms = delay {
                Text("\(ms) ms")
                    .font(.caption2.monospaced())
                    .foregroundStyle(bestPingColor(ms))
                    .contentTransition(.numericText())
            } else {
                Text("—")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            (isActive || isSwitching) ? Color.green.opacity(0.06) : Color.clear
        )
        .hoverEffect(.highlight)
        .contentShape(Rectangle())
        .onTapGesture {
            // Block double-taps only during active gRPC switching
            guard switchingTag == nil else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

            // Always save preference immediately — visual feedback works both online and offline
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                appState.selectPreferredServer(tag: server.tag)
            }

            if isLive {
                // gRPC: apply instantly without VPN reconnect
                switchingTag = server.tag
                let tag = server.tag
                if let sel = serverSelectorGroup,
                   sel.items.contains(where: { $0.tag == server.tag }) {
                    // New config: selector has individual servers → select directly (reliable)
                    stats.selectOutbound(groupTag: sel.tag, outboundTag: server.tag)
                } else {
                    // Old config: find per-country urltest group and point selector to it
                    let urltestGroups = groups.filter { $0.type == "urltest" }
                    let autoGroupTag = urltestGroups.max(by: { $0.items.count < $1.items.count })?.tag ?? ""
                    let countryGroup = groups.first {
                        $0.type == "urltest" &&
                        $0.tag != autoGroupTag &&
                        $0.items.contains { $0.tag == server.tag }
                    }
                    if let cg = countryGroup {
                        stats.selectOutbound(groupTag: cg.tag, outboundTag: server.tag)
                        if let sel = serverSelectorGroup {
                            stats.selectOutbound(groupTag: sel.tag, outboundTag: cg.tag)
                        }
                    } else {
                        stats.selectOutbound(groupTag: autoGroupTag, outboundTag: server.tag)
                    }
                }
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    withAnimation { if switchingTag == tag { switchingTag = nil } }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            } else {
                // Offline: preference saved, will apply on next VPN connect
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    // MARK: - Helpers

    /// Fast country key from tag — no object allocation.
    private func countryKeyFromTag(_ tag: String) -> String {
        let t = tag.lowercased()
        if t.contains("cdn") { return "cdn" }
        if tag.contains("🇳🇱") || t.contains("nl") { return "nl" }
        if tag.contains("🇩🇪") || t.contains("de") { return "de" }
        if tag.contains("🇷🇺") || t.contains("ru") || t.contains("москва") { return "ru" }
        return "other"
    }

    /// Best ping for a country group — live gRPC or offline TCP.
    private func bestPingForCountry(_ country: CountryGroup) -> Int32? {
        if isLive && country.bestDelay > 0 {
            return country.bestDelay
        }
        // TCP ping fallback (offline mode or when live gRPC has no delay data yet)
        let pings = country.serverTags.compactMap { tag -> Int32? in
            guard let ms = pinger.results[tag], ms > 0 else { return nil }
            return ms
        }
        return pings.min()
    }

    private func bestPingColor(_ delay: Int32) -> Color {
        if delay <= 0 { return Color(.systemGray3) }
        if delay < 100 { return .green }
        if delay < 300 { return .yellow }
        return .red
    }

    /// Flag drawn as colored horizontal stripes — fills the badge square perfectly.
    @ViewBuilder
    private func flagBackground(for countryId: String) -> some View {
        switch countryId {
        case "nl":
            VStack(spacing: 0) {
                Color(red: 0.682, green: 0.106, blue: 0.153) // #AE1B27
                Color.white
                Color(red: 0.122, green: 0.231, blue: 0.518) // #1F3B84
            }
        case "de":
            VStack(spacing: 0) {
                Color(red: 0.13, green: 0.13, blue: 0.13)    // near-black
                Color(red: 0.816, green: 0.0, blue: 0.051)   // #D0000D
                Color(red: 1.0, green: 0.796, blue: 0.0)     // #FFCB00
            }
        case "ru":
            VStack(spacing: 0) {
                Color.white
                Color(red: 0.0, green: 0.298, blue: 0.686)   // #004CB0
                Color(red: 0.859, green: 0.102, blue: 0.102) // #DB1A1A
            }
        default:
            Color(.systemGray6)
        }
    }

}
