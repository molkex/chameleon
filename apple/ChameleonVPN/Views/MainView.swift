import SwiftUI
import NetworkExtension

struct MainView: View {
    @Environment(AppState.self) private var app

    @State private var showServers = false
    @State private var showDebugLogs = false

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
                .padding(.bottom, 30)
            }

            // Debug button (top-right)
            VStack {
                HStack {
                    Spacer()
                    Button {
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
        .sheet(isPresented: $showServers) {
            ServerListView()
                .environment(app)
        }
        .sheet(isPresented: $showDebugLogs) {
            DebugLogsView()
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
                    app.configStore.selectedServerTag = nil
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(.cyan)
                        Text("Auto (best ping)")
                        Spacer()
                        if app.configStore.selectedServerTag == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.cyan)
                        }
                    }
                }

                // Servers from config
                ForEach(app.servers, id: \.tag) { group in
                    if group.selectable {
                        Section(group.tag) {
                            ForEach(group.items, id: \.tag) { server in
                                Button {
                                    app.selectServer(groupTag: group.tag, serverTag: server.tag)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(server.tag)
                                        Spacer()
                                        if app.configStore.selectedServerTag == server.tag {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.cyan)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
