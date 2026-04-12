import SwiftUI
import NetworkExtension

struct MainView: View {
    @Environment(AppState.self) private var app

    @State private var showServers = false
    @State private var showDebugLogs = false
    @State private var preloadedTunnelLines: [String] = []
    @State private var preloadedStderrLines: [String] = []
    /// Cached "v1.0.0(1) sni:..." string. Computed once on appear and on foreground
    /// to avoid re-parsing the config JSON on every VPN status change re-render.
    @State private var cachedBuildInfoLine: String = ""

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer()

                // Status text
                Text(statusText)
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundStyle(statusColor)

                // Connect button
                Button {
                    TunnelFileLogger.log("TAP: connect button (isConnected=\(self.isConnected), isLoading=\(self.app.isLoading))", category: "ui")
                    Task { await app.toggleVPN() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(buttonGradient)
                            .frame(width: 160, height: 160)
                            .shadow(color: buttonShadowColor, radius: isConnected ? 30 : 10)

                        if app.isLoading || isConnecting {
                            ProgressView()
                                .scaleEffect(1.5)
                                .tint(.white)
                        } else {
                            Image(systemName: isConnected ? "power" : "power")
                                .font(.system(size: 50, weight: .light))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .disabled(app.isLoading)
                .animation(.spring(response: 0.5), value: isConnected)

                // Timer
                if isConnected, let connectedAt = app.vpnConnectedAt {
                    TimerView(since: connectedAt)
                        .transition(.opacity)
                }

                Spacer()

                // Server selector
                Button {
                    TunnelFileLogger.log("TAP: open server list")
                    showServers = true
                } label: {
                    HStack {
                        Image(systemName: "globe")
                        Text(selectedServerName)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding()
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal)

                // Subscription status
                subscriptionStatusView
                    .padding(.bottom, 2)

                // Version + config hash
                Text(cachedBuildInfoLine)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray.opacity(0.4))
                    .padding(.bottom, 16)
            }

            // Debug button (top-right)
            VStack {
                HStack {
                    Spacer()
                    Button {
                        TunnelFileLogger.log("TAP: debug logs button")
                        // Preload logs before opening sheet
                        preloadedTunnelLines = TunnelFileLogger.readLog().components(separatedBy: "\n")
                        preloadedStderrLines = TunnelFileLogger.readStderrLog().components(separatedBy: "\n")
                        showDebugLogs = true
                    } label: {
                        Image(systemName: "ladybug")
                            .font(.title3)
                            .foregroundStyle(.gray.opacity(0.6))
                            .padding(12)
                    }
                }
                Spacer()
            }
            .padding(.top, 50)

            // Error toast
            if let error = app.errorMessage {
                VStack {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.red.opacity(0.8), in: Capsule())
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
            ServerListView()
                .environment(app)
        }
        .sheet(isPresented: $showDebugLogs) {
            DebugLogsView(
                preloadedTunnelLines: preloadedTunnelLines,
                preloadedStderrLines: preloadedStderrLines
            )
            .environment(app)
        }
    }

    private var isConnected: Bool {
        app.vpnManager.status == .connected
    }

    private var isConnecting: Bool {
        app.vpnManager.status == .connecting || app.vpnManager.status == .reasserting
    }

    private var statusText: String {
        switch app.vpnManager.status {
        case .connected: "Connected"
        case .connecting: "Connecting..."
        case .disconnecting: "Disconnecting..."
        case .reasserting: "Reconnecting..."
        default: "Not Connected"
        }
    }

    private var statusColor: Color {
        isConnected ? .green : .gray
    }

    private var buttonGradient: LinearGradient {
        if isConnected {
            LinearGradient(colors: [.green, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            LinearGradient(colors: [.gray.opacity(0.4), .gray.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var buttonShadowColor: Color {
        isConnected ? .cyan.opacity(0.4) : .clear
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

    private var selectedServerName: String {
        if let tag = app.configStore.selectedServerTag {
            // Find server name from config
            for group in app.servers {
                if let item = group.items.first(where: { $0.tag == tag }) {
                    return item.tag
                }
                if group.tag == tag { return group.tag }
            }
            return tag
        }
        return "Auto"
    }

    @ViewBuilder
    private var subscriptionStatusView: some View {
        if let expire = app.subscriptionExpire {
            let daysLeft = Calendar.current.dateComponents([.day], from: .now, to: expire).day ?? 0
            Group {
                if daysLeft < 0 {
                    Label("Subscription expired", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                } else if daysLeft <= 3 {
                    Label("Expires in \(daysLeft) day\(daysLeft == 1 ? "" : "s")!", systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                } else if daysLeft <= 7 {
                    Label("Expires in \(daysLeft) days", systemImage: "clock")
                        .foregroundStyle(.yellow.opacity(0.85))
                } else {
                    Text("Active until \(expire.formatted(.dateTime.day().month(.abbreviated)))")
                        .foregroundStyle(.gray.opacity(0.45))
                }
            }
            .font(.caption)
        }
    }
}

// MARK: - Timer

struct TimerView: View {
    let since: Date
    @State private var elapsed: TimeInterval = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(formatted)
            .font(.system(.title2, design: .monospaced))
            .foregroundStyle(.gray)
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

// MARK: - Server List

struct ServerListView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Auto option
                Button {
                    TunnelFileLogger.log("TAP: server row 'Auto'", category: "ui")
                    app.selectServer(groupTag: "Proxy", serverTag: "Auto")
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(.cyan)
                        Text("Auto (best ping)")
                            .foregroundStyle(.primary)
                        Spacer()
                        if app.configStore.selectedServerTag == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.cyan)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Servers from config — show only selector groups (not urltest).
                // urltest groups would duplicate rows since "Auto" is shown above.
                ForEach(app.servers.filter { $0.type == "selector" && $0.selectable }, id: \.tag) { group in
                    Section(group.tag) {
                        ForEach(group.items, id: \.tag) { server in
                            Button {
                                TunnelFileLogger.log("TAP: server row '\(server.tag)' in group '\(group.tag)'", category: "ui")
                                app.selectServer(groupTag: group.tag, serverTag: server.tag)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(server.tag)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if app.configStore.selectedServerTag == server.tag {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.cyan)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Servers")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { TunnelFileLogger.log("ServerListView: appeared, groups=\(app.servers.count)", category: "ui") }
            .onDisappear { TunnelFileLogger.log("ServerListView: disappeared", category: "ui") }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        TunnelFileLogger.log("TAP: Done in server list", category: "ui")
                        dismiss()
                    }
                }
            }
        }
    }
}
