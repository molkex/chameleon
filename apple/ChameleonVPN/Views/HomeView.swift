import SwiftUI
import NetworkExtension

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    private var vpn: VPNManager { appState.vpnManager }
    private var stats: CommandClientWrapper { appState.commandClient }

    // MARK: - Animation state

    @State private var pulsing = false
    @State private var buttonScale: CGFloat = 1.0
    @State private var showSpeedStats = false
    @State private var glowIntensity: Double = 0.0
    @State private var statusTextID = UUID()
    @State private var spinnerRotation: Double = 0
    @State private var connectionTimerTask: Task<Void, Never>? = nil
    @State private var connectionTimeText: String = ""
    @State private var isApplyingMode = false
    @State private var showModeInfo = false


    private var isConnected: Bool { vpn.isConnected }
    private var isProcessing: Bool { vpn.isProcessing || appState.isLoading }
    private var isDark: Bool { colorScheme == .dark }
    private var accentGreen: Color { Color(red: 0.2, green: 0.84, blue: 0.42) }

    private var statusText: String {
        if appState.isLoading { return "Загрузка..." }
        switch vpn.status {
        case .connected:      return "Подключено"
        case .connecting:     return "Подключение..."
        case .disconnecting:  return "Отключение..."
        case .disconnected:   return "Отключено"
        case .reasserting:    return "Переподключение..."
        case .invalid:        return "Не настроено"
        @unknown default:     return "Неизвестно"
        }
    }

    private var statusColor: Color {
        switch vpn.status {
        case .connected:             return accentGreen
        case .connecting, .reasserting: return .yellow
        case .disconnecting:         return .orange
        default:                     return Color(.systemGray3)
        }
    }

    var body: some View {
        ZStack {
            backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                statusSection
                    .padding(.bottom, 12)

                serverPill
                    .padding(.bottom, 36)

                powerButtonSection

                vpnModeToggle
                    .padding(.top, 32)

                Spacer()

                speedStatsPanel
                    .padding(.bottom, 20)

                Spacer().frame(height: 8)
            }
        }
        .alert("Ошибка подключения", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .sheet(isPresented: $showModeInfo) { modeInfoSheet }
        .onChange(of: vpn.isConnected) { _, connected in
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                showSpeedStats = connected
            }
            if connected {
                startPulseAnimation()
                startGlowAnimation()
                startConnectionTimer()
            } else {
                stopAnimations()
                stopConnectionTimer()
            }
        }
        .onChange(of: vpn.isProcessing) { _, processing in
            if processing {
                spinnerRotation = 0
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    spinnerRotation = 360
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { spinnerRotation = 0 }
            }
        }
        .onChange(of: vpn.status) { _, _ in statusTextID = UUID() }
        .onAppear {
            if isConnected {
                showSpeedStats = true
                startPulseAnimation()
                startGlowAnimation()
                startConnectionTimer()
            }
            if isProcessing {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    spinnerRotation = 360
                }
            }
        }
        .onDisappear { stopConnectionTimer() }
    }

    // MARK: - Background

    // Subtle connected glow only — clean background is provided by TabRootView
    private var backgroundGradient: some View {
        ZStack {
            if isConnected {
                RadialGradient(
                    colors: [accentGreen.opacity(isDark ? 0.15 : 0.08), .clear],
                    center: .init(x: 0.5, y: 0.55),
                    startRadius: 80,
                    endRadius: 580
                )
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.5), value: isConnected)
    }

    // MARK: - Status Section

    private var statusSection: some View {
        VStack(spacing: 6) {
            Text(LocalizedStringKey(statusText))
                .id(statusTextID)
                .font(.title2.weight(.semibold))
                .foregroundStyle(statusColor)
                .contentTransition(.numericText())
                .transition(.asymmetric(
                    insertion: .push(from: .bottom).combined(with: .opacity),
                    removal: .push(from: .top).combined(with: .opacity)
                ))
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: vpn.status)

            if isConnected && !connectionTimeText.isEmpty {
                Text(connectionTimeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .animation(.easeInOut(duration: 0.3), value: connectionTimeText)
            }
        }
    }

    // MARK: - Server Pill

    private var displayedServer: ServerItem? {
        if let liveServer = stats.selectedServer { return liveServer }
        if let savedTag = appState.selectedServerTag {
            let temp = ServerItem(id: savedTag, tag: savedTag, type: "urltest", delay: 0, delayTime: 0)
            if temp.countryKey != "other" && temp.countryKey != "cdn" {
                if let autoGroup = appState.configServers.first(where: { $0.type == "urltest" }) {
                    if let rep = autoGroup.items.first(where: { $0.countryKey == temp.countryKey }) {
                        return rep
                    }
                }
                return temp
            }
            if let autoGroup = appState.configServers.first(where: { $0.type == "urltest" }) {
                return autoGroup.items.first(where: { $0.tag == savedTag })
            }
        }
        if let autoGroup = appState.configServers.first(where: { $0.type == "urltest" }) {
            return autoGroup.items.first
        }
        return nil
    }

    private var serverDisplayName: String {
        guard let server = displayedServer else { return "Авто" }
        return server.homePillLabel
    }

    private var serverPill: some View {
        HStack(spacing: 8) {
            if let server = displayedServer, server.countryKey != "other" {
                Text(server.flagEmoji)
                    .font(.system(size: 18))
            }
            Text(serverDisplayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary.opacity(0.8))
                .lineLimit(1)
            if let server = displayedServer, server.delay > 0 {
                Text("·")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.3))
                Text("\(server.delay)ms")
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(accentGreen)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: displayedServer?.tag)
    }

    // MARK: - Power Button

    private var powerButtonSection: some View {
        ZStack {
            // Single expanding pulse ring when connected
            if isConnected {
                Circle()
                    .stroke(accentGreen.opacity(pulsing ? 0.0 : 0.30), lineWidth: 1.5)
                    .frame(width: 196, height: 196)
                    .scaleEffect(pulsing ? 1.5 : 1.0)
            }

            // Soft outer glow
            Circle()
                .fill(accentGreen.opacity(isConnected ? glowIntensity : 0.0))
                .frame(width: 190, height: 190)
                .blur(radius: 32)

            // Processing ring
            if isProcessing {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(statusColor.opacity(0.6), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(spinnerRotation))
            }

            // Main button
            Button {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { buttonScale = 0.92 }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6).delay(0.1)) { buttonScale = 1.0 }
                Task { await appState.toggleVPN() }
            } label: {
                ZStack {
                    // Base circle
                    Circle()
                        .fill(
                            isConnected
                            ? AnyShapeStyle(LinearGradient(
                                colors: [accentGreen, Color(red: 0.1, green: 0.7, blue: 0.35)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            : AnyShapeStyle(LinearGradient(
                                colors: [Color(white: isDark ? 0.26 : 0.88), Color(white: isDark ? 0.20 : 0.82)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                        )
                        .frame(width: 180, height: 180)
                        .shadow(
                            color: isConnected ? accentGreen.opacity(0.40) : Color.black.opacity(0.10),
                            radius: isConnected ? 24 : 8,
                            y: isConnected ? 0 : 4
                        )

                    // Inner highlight
                    Circle()
                        .fill(RadialGradient(
                            colors: [Color.white.opacity(0.22), .clear],
                            center: .init(x: 0.4, y: 0.35),
                            startRadius: 0, endRadius: 90
                        ))
                        .frame(width: 180, height: 180)

                    // Icon
                    if isProcessing {
                        Circle()
                            .trim(from: 0, to: 0.7)
                            .stroke(
                                vpn.status == .connecting ? Color.white.opacity(0.9) : Color.primary.opacity(0.6),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .frame(width: 50, height: 50)
                            .rotationEffect(.degrees(spinnerRotation))
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: 58, weight: .light))
                            .foregroundStyle(isConnected ? .white : .primary)
                    }
                }
            }
            .scaleEffect(buttonScale)
            .disabled(isProcessing)
            .animation(.spring(response: 0.5, dampingFraction: 0.75), value: isConnected)
            .accessibilityLabel(isConnected ? "Отключить VPN" : "Подключить VPN")
            .accessibilityHint(isProcessing ? "Подождите, выполняется операция" : "")
            .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.7), trigger: isConnected)
            .keyboardShortcut("k", modifiers: .command)
        }
    }

    // MARK: - VPN Mode Toggle

    private var vpnModeToggle: some View {
        HStack(spacing: 10) {
            if isApplyingMode {
                ProgressView()
                    .tint(accentGreen)
                    .scaleEffect(0.75)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: appState.configStore.vpnMode == "fullvpn" ? "globe" : "shield.lefthalf.filled")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accentGreen)
            }

            Text(appState.configStore.vpnMode == "fullvpn" ? "Весь трафик" : "Умный режим")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary.opacity(0.85))

            Button {
                showModeInfo = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { appState.configStore.vpnMode == "fullvpn" },
                set: { newVal in
                    guard !isApplyingMode else { return }
                    isApplyingMode = true
                    Task {
                        await appState.setVPNMode(newVal ? "fullvpn" : "smart")
                        isApplyingMode = false
                    }
                }
            ))
            .tint(accentGreen)
            .labelsHidden()
            .scaleEffect(0.85)
            .disabled(isApplyingMode)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isApplyingMode)
    }

    // MARK: - Mode Info Sheet

    private var modeInfoSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                infoCard(
                    icon: "shield.lefthalf.filled",
                    color: accentGreen,
                    title: "Умный режим",
                    description: "Только заблокированные сайты и сервисы идут через VPN. Остальной трафик — напрямую. Работает быстрее и меньше расходует заряд."
                )

                infoCard(
                    icon: "globe",
                    color: Color(red: 0.3, green: 0.6, blue: 1.0),
                    title: "Весь трафик",
                    description: "Весь интернет-трафик идёт через VPN. Максимальная защита и анонимность, но чуть медленнее."
                )

                Spacer()
            }
            .padding(20)
            .navigationTitle("Режим VPN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { showModeInfo = false }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func infoCard(icon: String, color: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Speed Stats

    private var speedStatsPanel: some View {
        Group {
            if showSpeedStats {
                VStack(spacing: 14) {
                    if stats.statsAvailable {
                        HStack(spacing: 0) {
                            speedCard(
                                icon: "arrow.up.circle.fill",
                                color: accentGreen,
                                speed: stats.formattedUploadSpeed,
                                total: stats.formattedUploadTotal,
                                label: "Отправлено"
                            )
                            Divider().frame(height: 50).padding(.horizontal, 4)
                            speedCard(
                                icon: "arrow.down.circle.fill",
                                color: .cyan,
                                speed: stats.formattedDownloadSpeed,
                                total: stats.formattedDownloadTotal,
                                label: "Получено"
                            )
                        }

                        // Connection count with clearer label
                        let total = stats.connectionsIn + stats.connectionsOut
                        if total > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "network")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("\(total)")
                                    .font(.caption.monospaced().weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                                Text("открытых соединений")
                                    .font(.caption)
                                    .foregroundStyle(.secondary.opacity(0.7))
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.shield.fill").foregroundStyle(accentGreen)
                            Text("VPN активен")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 18).padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.15), Color.white.opacity(0.05)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.5
                                )
                        )
                        .shadow(color: .black.opacity(0.08), radius: 15, y: 5)
                }
                .padding(.horizontal, 20)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)),
                    removal: .move(edge: .bottom).combined(with: .opacity)
                ))
            }
        }
        .animation(.spring(response: 0.7, dampingFraction: 0.8), value: showSpeedStats)
    }

    private func speedCard(icon: String, color: Color, speed: String, total: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .symbolEffect(.pulse, options: .repeating, isActive: isConnected)
            Text(speed)
                .font(.callout.monospaced().weight(.semibold))
                .contentTransition(.numericText())
                .animation(.spring(response: 0.3), value: speed)
            Text(total)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Animations

    private func startPulseAnimation() {
        pulsing = false
        withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) {
            pulsing = true
        }
    }

    private func startGlowAnimation() {
        withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
            glowIntensity = 0.22
        }
    }

    private func stopAnimations() {
        pulsing = false
        withAnimation(.easeOut(duration: 0.5)) {
            glowIntensity = 0.0
        }
    }

    // MARK: - Connection Timer

    private func startConnectionTimer() {
        connectionTimerTask?.cancel()
        let start = appState.vpnConnectedAt ?? Date()
        connectionTimeText = Self.formatElapsed(Int(Date().timeIntervalSince(start)))
        connectionTimerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                let base = appState.vpnConnectedAt ?? start
                connectionTimeText = Self.formatElapsed(Int(Date().timeIntervalSince(base)))
            }
        }
    }

    private func stopConnectionTimer() {
        connectionTimerTask?.cancel()
        connectionTimerTask = nil
        connectionTimeText = ""
    }

    private static func formatElapsed(_ elapsed: Int) -> String {
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}
