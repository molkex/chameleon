import SwiftUI
import Network

struct DebugLogsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var tunnelLog = ""
    @State private var stderrLog = ""
    @State private var diagnostics = ""
    @State private var networkTestResults = ""
    @State private var isTestingNetwork = false
    @State private var selectedTab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker
                Picker("Log", selection: $selectedTab) {
                    Text("Tunnel").tag(0)
                    Text("stderr").tag(1)
                    Text("Diag").tag(2)
                    Text("Network").tag(3)
                }
                .pickerStyle(.segmented)
                .padding()

                // Log content
                ScrollView {
                    Text(currentLog)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .textSelection(.enabled)
                }
                .background(.black)
            }
            .background(.black)
            .navigationTitle("Debug Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        refreshLogs()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }

                    ShareLink(item: allLogsText) {
                        Image(systemName: "square.and.arrow.up")
                    }

                    Button {
                        TunnelFileLogger.clear()
                        refreshLogs()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .onAppear {
            refreshLogs()
        }
    }

    private var currentLog: String {
        switch selectedTab {
        case 0: return tunnelLog.isEmpty ? "(no tunnel logs yet)" : tunnelLog
        case 1: return stderrLog.isEmpty ? "(no stderr logs yet)" : stderrLog
        case 2: return diagnostics.isEmpty ? "(tap refresh to load)" : diagnostics
        case 3: return networkTestResults.isEmpty ? "Tap refresh ↻ to run network test" : networkTestResults
        default: return ""
        }
    }

    private var allLogsText: String {
        """
        === TUNNEL DEBUG LOG ===
        \(tunnelLog)

        === STDERR LOG ===
        \(stderrLog)

        === DIAGNOSTICS ===
        \(diagnostics)
        """
    }

    private func refreshLogs() {
        tunnelLog = TunnelFileLogger.readLog()
        stderrLog = TunnelFileLogger.readStderrLog()
        fetchDiagnostics()
        if selectedTab == 3 { runNetworkTest() }
    }

    private func fetchDiagnostics() {
        Task {
            guard let data = "diagnostics".data(using: .utf8) else { return }
            do {
                if let response = try await app.vpnManager.sendMessage(data),
                   let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any] {
                    var lines: [String] = []
                    for (key, value) in json.sorted(by: { $0.key < $1.key }) {
                        lines.append("\(key): \(value)")
                    }
                    diagnostics = lines.joined(separator: "\n")
                } else {
                    diagnostics = "(VPN not connected or no response)"
                }
            } catch {
                diagnostics = "Error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Network Connectivity Test

    private func runNetworkTest() {
        guard !isTestingNetwork else { return }
        isTestingNetwork = true
        networkTestResults = "🔄 Testing network connectivity...\n\n"

        // Detect current network type
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "nettest")
        monitor.pathUpdateHandler = { path in
            let netType: String
            if path.usesInterfaceType(.wifi) { netType = "WiFi" }
            else if path.usesInterfaceType(.cellular) { netType = "Cellular (LTE/5G)" }
            else if path.usesInterfaceType(.wiredEthernet) { netType = "Ethernet" }
            else { netType = "Unknown" }

            Task { @MainActor in
                networkTestResults += "📶 Network: \(netType)\n"
                networkTestResults += "Internet: \(path.status == .satisfied ? "✅ Available" : "❌ No internet")\n\n"
                monitor.cancel()
                await testAllEndpoints()
            }
        }
        monitor.start(queue: queue)
    }

    private func testAllEndpoints() async {
        let tcpEndpoints: [(name: String, host: String, port: UInt16)] = [
            // SPB Relay
            ("SPB Relay → DE :443",     "185.218.0.43", 443),
            ("SPB Relay → DE :2096",    "185.218.0.43", 2096),
            ("SPB Relay → NL (VLESS)",  "185.218.0.43", 2098),
            ("SPB Relay HTTP",          "185.218.0.43", 80),
            ("SPB Relay HTTPS",         "185.218.0.43", 443),
            // Direct servers
            ("DE Direct (VLESS)",       "162.19.242.30", 2096),
            ("DE Direct HTTP",          "162.19.242.30", 80),
            ("NL Direct (VLESS)",       "194.135.38.90", 2096),
            // General internet
            ("Cloudflare DNS",          "1.1.1.1",       443),
            ("Google DNS",              "8.8.8.8",        53),
            ("Cloudflare (razblokirator)", "104.21.0.1", 443),
        ]

        let udpEndpoints: [(name: String, host: String, port: UInt16)] = [
            ("DE Hysteria2 (UDP)",      "162.19.242.30", 8443),
            ("NL Hysteria2 (UDP)",      "194.135.38.90", 8443),
        ]

        // --- TCP Tests ---
        networkTestResults += "--- TCP Connection Tests ---\n"
        networkTestResults += "(timeout = 5s per test)\n\n"

        for ep in tcpEndpoints {
            let result = await testTCP(host: ep.host, port: ep.port)
            let icon = result.success ? "✅" : "❌"
            let time = result.success ? String(format: "%.0fms", result.time * 1000) : result.error
            networkTestResults += "\(icon) \(ep.name)\n   \(ep.host):\(ep.port) → \(time)\n\n"
        }

        // --- UDP Tests ---
        networkTestResults += "--- UDP Connection Tests ---\n"
        networkTestResults += "(Hysteria2 uses QUIC/UDP)\n\n"

        for ep in udpEndpoints {
            let result = await testUDP(host: ep.host, port: ep.port)
            let icon = result.success ? "✅" : "❌"
            let time = result.success ? String(format: "%.0fms", result.time * 1000) : result.error
            networkTestResults += "\(icon) \(ep.name)\n   \(ep.host):\(ep.port) → \(time)\n\n"
        }

        // --- HTTP Fetch Tests (goes through VPN if connected) ---
        networkTestResults += "--- HTTP Fetch Tests ---\n"
        networkTestResults += "(tests actual data flow, goes through VPN if on)\n\n"

        let httpTests: [(name: String, url: String)] = [
            ("Google generate_204",  "https://www.gstatic.com/generate_204"),
            ("Cloudflare trace",     "https://1.1.1.1/cdn-cgi/trace"),
            ("Backend health",       "https://razblokirator.ru/health"),
            ("Backend health (direct IP)", "http://162.19.242.30/health"),
        ]

        for test in httpTests {
            let result = await testHTTP(url: test.url)
            let icon = result.success ? "✅" : "❌"
            let detail = result.success ? "\(result.statusCode) (\(String(format: "%.0fms", result.time * 1000)))" : result.error
            networkTestResults += "\(icon) \(test.name)\n   \(test.url)\n   → \(detail)\n\n"
        }

        // --- Summary ---
        networkTestResults += "--- Summary ---\n"
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        networkTestResults += "Tested at: \(timestamp)\n"
        networkTestResults += "VPN connected: \(app.vpnManager.isConnected ? "Yes" : "No")\n"
        networkTestResults += "\n"
        networkTestResults += "💡 TCP ✅ but VPN fails → routing loop or Reality mismatch\n"
        networkTestResults += "💡 HTTP fetch ❌ with VPN ON → VPN tunnel broken\n"
        networkTestResults += "💡 HTTP fetch ✅ without VPN → server reachable directly\n"
        networkTestResults += "💡 UDP ❌ → ISP blocks UDP or HY2 not running\n"
        networkTestResults += "\n⏱ Test completed!\n"

        isTestingNetwork = false
    }

    private func testTCP(host: String, port: UInt16) async -> (success: Bool, time: TimeInterval, error: String) {
        let start = CFAbsoluteTimeGetCurrent()
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            let queue = DispatchQueue(label: "tcp-test-\(host)-\(port)")
            var completed = false

            // Timeout after 5 seconds
            queue.asyncAfter(deadline: .now() + 5) {
                guard !completed else { return }
                completed = true
                connection.cancel()
                continuation.resume(returning: (false, 5.0, "TIMEOUT (5s)"))
            }

            connection.stateUpdateHandler = { state in
                guard !completed else { return }
                switch state {
                case .ready:
                    completed = true
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    connection.cancel()
                    continuation.resume(returning: (true, elapsed, ""))
                case .failed(let error):
                    completed = true
                    connection.cancel()
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    continuation.resume(returning: (false, elapsed, error.localizedDescription))
                case .cancelled:
                    guard !completed else { return }
                    completed = true
                    continuation.resume(returning: (false, 0, "cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func testUDP(host: String, port: UInt16) async -> (success: Bool, time: TimeInterval, error: String) {
        let start = CFAbsoluteTimeGetCurrent()
        return await withCheckedContinuation { continuation in
            let params = NWParameters.udp
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: params
            )
            let queue = DispatchQueue(label: "udp-test-\(host)-\(port)")
            var completed = false

            queue.asyncAfter(deadline: .now() + 5) {
                guard !completed else { return }
                completed = true
                connection.cancel()
                continuation.resume(returning: (false, 5.0, "TIMEOUT (5s)"))
            }

            connection.stateUpdateHandler = { state in
                guard !completed else { return }
                switch state {
                case .ready:
                    // UDP is "connectionless" — send a probe to confirm path
                    connection.send(content: Data([0x00]), completion: .contentProcessed { error in
                        guard !completed else { return }
                        completed = true
                        let elapsed = CFAbsoluteTimeGetCurrent() - start
                        connection.cancel()
                        if let error {
                            continuation.resume(returning: (false, elapsed, error.localizedDescription))
                        } else {
                            continuation.resume(returning: (true, elapsed, ""))
                        }
                    })
                case .failed(let error):
                    completed = true
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    connection.cancel()
                    continuation.resume(returning: (false, elapsed, error.localizedDescription))
                case .cancelled:
                    guard !completed else { return }
                    completed = true
                    continuation.resume(returning: (false, 0, "cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func testHTTP(url: String) async -> (success: Bool, statusCode: Int, time: TimeInterval, error: String) {
        let start = CFAbsoluteTimeGetCurrent()
        guard let requestURL = URL(string: url) else {
            return (false, 0, 0, "Invalid URL")
        }
        var request = URLRequest(url: requestURL, timeoutInterval: 10)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status >= 200 && status < 400, status, elapsed, "")
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (false, 0, elapsed, error.localizedDescription)
        }
    }
}
