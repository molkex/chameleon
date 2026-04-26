import SwiftUI
import Network

struct DebugLogsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    // Preloaded data from MainView — available instantly
    var preloadedTunnelLines: [String]
    var preloadedStderrLines: [String]

    @State private var tunnelLines: [String] = []
    @State private var stderrLines: [String] = []
    @State private var diagnostics = ""
    @State private var networkTestResults = ""
    @State private var isTestingNetwork = false
    @State private var selectedTab = 0
    @State private var showCopiedToast = false

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

                // Log content — lazy line-by-line rendering
                ScrollViewReader { proxy in
                    ScrollView {
                        switch selectedTab {
                        case 0:
                            lazyLogContent(lines: tunnelLines, empty: "(no tunnel logs yet)", id: "tunnel")
                        case 1:
                            lazyLogContent(lines: stderrLines, empty: "(no stderr logs yet)", id: "stderr")
                        case 2:
                            plainTextContent(diagnostics.isEmpty ? "(tap refresh to load)" : diagnostics)
                        case 3:
                            plainTextContent(networkTestResults.isEmpty ? "Tap refresh ↻ to run network test" : networkTestResults)
                        default:
                            EmptyView()
                        }
                    }
                    .background(.black)
                    .onChange(of: selectedTab) { _, tab in
                        loadTabIfNeeded(tab)
                        // Scroll to bottom for log tabs
                        if tab == 0 {
                            proxy.scrollTo("tunnel-end", anchor: .bottom)
                        } else if tab == 1 {
                            proxy.scrollTo("stderr-end", anchor: .bottom)
                        }
                    }
                }
            }
            .background(.black)
            .navigationTitle("Debug Logs")
            .iosInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: PlatformToolbarPlacement.leading.resolved) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: PlatformToolbarPlacement.trailing.resolved) {
                    // Copy compact report for Claude
                    Button {
                        PlatformPasteboard.setString(buildClaudeReport())
                        showCopiedToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showCopiedToast = false
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }

                    Button {
                        refreshCurrentTab()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }

                    ShareLink(item: allLogsText) {
                        Image(systemName: "square.and.arrow.up")
                    }

                    Button {
                        TunnelFileLogger.clear()
                        tunnelLines = []
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if showCopiedToast {
                Text("Copied for Claude")
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.green.opacity(0.9), in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 60)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showCopiedToast)
        .onAppear {
            // Show preloaded data first (instant display), then refresh from
            // disk so logs written *after* the Settings screen opened are
            // visible too (on macOS the extension often writes between
            // Settings opening and Debug Logs opening).
            tunnelLines = preloadedTunnelLines
            stderrLines = preloadedStderrLines
            Task.detached(priority: .userInitiated) {
                let tunnel = TunnelFileLogger.readLog().components(separatedBy: "\n")
                let stderr = TunnelFileLogger.readStderrLog().components(separatedBy: "\n")
                await MainActor.run {
                    tunnelLines = tunnel
                    stderrLines = stderr
                }
            }
        }
    }

    // MARK: - Lazy Log Rendering

    @ViewBuilder
    private func lazyLogContent(lines: [String], empty: String, id: String) -> some View {
        if lines.isEmpty || (lines.count == 1 && lines[0].isEmpty) {
            plainTextContent(empty)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(lineColor(line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Color.clear.frame(height: 1).id("\(id)-end")
            }
            .padding(.horizontal, 12)
            .textSelection(.enabled)
        }
    }

    private func plainTextContent(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .textSelection(.enabled)
    }

    private func lineColor(_ line: String) -> Color {
        if line.contains("[ERROR]") || line.contains("[FATAL]") { return .red }
        if line.contains("[WARN]") { return .yellow }
        if line.contains("[DEBUG]") || line.contains("[TRACE]") { return .green.opacity(0.6) }
        return .green
    }

    // MARK: - Tab Loading

    private func loadTabIfNeeded(_ tab: Int) {
        switch tab {
        case 2 where diagnostics.isEmpty:
            fetchDiagnostics()
        case 3 where networkTestResults.isEmpty:
            runNetworkTest()
        default:
            break
        }
    }

    private func refreshCurrentTab() {
        switch selectedTab {
        case 0:
            Task.detached {
                let lines = TunnelFileLogger.readLog().components(separatedBy: "\n")
                await MainActor.run { tunnelLines = lines }
            }
        case 1:
            Task.detached {
                let lines = TunnelFileLogger.readStderrLog().components(separatedBy: "\n")
                await MainActor.run { stderrLines = lines }
            }
        case 2:
            fetchDiagnostics()
        case 3:
            runNetworkTest()
        default:
            break
        }
    }

    // MARK: - Share

    private var allLogsText: String {
        """
        === TUNNEL DEBUG LOG ===
        \(tunnelLines.joined(separator: "\n"))

        === STDERR LOG ===
        \(stderrLines.joined(separator: "\n"))

        === DIAGNOSTICS ===
        \(diagnostics)
        """
    }

    // MARK: - Claude Report

    /// Strip ANSI escape sequences (color codes from sing-box)
    private func stripANSI(_ text: String) -> String {
        // Matches ESC[ ... m  (including ␛ symbol used in some terminals)
        text.replacingOccurrences(
            of: "(␛|\\x1B|\\e)\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )
    }

    private func buildClaudeReport() -> String {
        // Pre-clean all lines from ANSI codes
        let cleanTunnel = tunnelLines.map { stripANSI($0) }
        let cleanStderr = stderrLines.map { stripANSI($0) }

        var report = "=== CHAMELEON DEBUG REPORT ===\n"

        // Timestamp & VPN status
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        report += "Time: \(now)\n"
        report += "VPN: \(app.vpnManager.isConnected ? "connected" : "disconnected")\n"

        // App version
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        report += "App: v\(appVersion) (\(buildNumber))\n"

        // Config version from sing-box config JSON
        if let configData = try? Data(contentsOf: AppConstants.configFileURL),
           let json = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
           let configVersion = json["config_version"] as? String {
            report += "Config: \(configVersion)\n"
        }

        if let connectedAt = app.vpnConnectedAt {
            let uptime = Int(Date().timeIntervalSince(connectedAt))
            let h = uptime / 3600; let m = (uptime % 3600) / 60; let s = uptime % 60
            report += "Uptime: \(String(format: "%02d:%02d:%02d", h, m, s))\n"
        }

        // Diagnostics (if loaded)
        if !diagnostics.isEmpty {
            report += "\n=== DIAGNOSTICS ===\n"
            report += diagnostics + "\n"
        }

        // Errors & warnings from tunnel log
        let errorLines = cleanTunnel.filter { line in
            line.contains("[ERROR]") || line.contains("[FATAL]") ||
            line.contains("[WARN]") || line.contains("ERROR:") ||
            line.contains("failed") || line.contains("TIMEOUT")
        }
        if !errorLines.isEmpty {
            report += "\n=== ERRORS & WARNINGS ===\n"
            for line in errorLines.suffix(30) {
                report += line + "\n"
            }
        }

        // Errors from stderr
        let stderrErrors = cleanStderr.filter { line in
            line.contains("error") || line.contains("Error") ||
            line.contains("fatal") || line.contains("panic")
        }
        if !stderrErrors.isEmpty {
            report += "\n=== STDERR ERRORS ===\n"
            for line in stderrErrors.suffix(20) {
                report += line + "\n"
            }
        }

        // Key events: tunnel start/stop, config source, network changes
        let eventKeywords = ["TUNNEL START", "TUNNEL STOP", "Config source:",
                             "sing-box started", "Stopping tunnel",
                             "Network switch", "NETWORK CHANGED",
                             "startOrReloadService"]
        let events = cleanTunnel.filter { line in
            eventKeywords.contains(where: { line.contains($0) })
        }
        if !events.isEmpty {
            report += "\n=== KEY EVENTS ===\n"
            for line in events.suffix(20) {
                report += line + "\n"
            }
        }

        // Last 30 meaningful lines (skip routine connection noise)
        let noisePatterns = [
            "TRACE",
            "connection download closed",
            "connection upload closed",
            "connection upload finished",
            "connection: initialize",
            "match[0] => sniff",
            "sniffed protocol:",
            "sniffed packet protocol:",
            "inbound connection from",
            "inbound connection to",
            "inbound packet connection",
            "dns: exchange ",              // routine DNS queries
            "dns: exchanged ",             // routine DNS responses (errors caught by ERRORS section)
            "dns: cached ",                // cached DNS results
            "match[1] protocol=dns",
            "match[2] network=udp",
            "connection closed: rejected",
            "attempt to sniff fragmented",
        ]
        let meaningfulLines = cleanTunnel.filter { line in
            !line.isEmpty &&
            !noisePatterns.contains(where: { line.contains($0) })
        }

        // Deduplicate outbound connections — keep only first per outbound name
        // e.g. show one "outbound/vless[🇩🇪 Germany]" line, not 20 to different IPs
        var seenOutboundNames = Set<String>()
        let deduped = meaningfulLines.filter { line in
            if line.contains("outbound connection to") && !line.contains("ERROR") {
                // Extract outbound name: "outbound/vless[🇩🇪 Germany]"
                if let range = line.range(of: "outbound/[^:]+", options: .regularExpression) {
                    let name = String(line[range])
                    if seenOutboundNames.contains(name) { return false }
                    seenOutboundNames.insert(name)
                }
            }
            return true
        }
        let tail = deduped.suffix(30)
        if !tail.isEmpty {
            report += "\n=== RECENT LOG (last 30 meaningful lines) ===\n"
            for line in tail {
                report += line + "\n"
            }
        }

        // Network test results (if run)
        if !networkTestResults.isEmpty {
            report += "\n=== NETWORK TEST ===\n"
            report += networkTestResults + "\n"
        }

        return report
    }

    // MARK: - Diagnostics

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
            ("NL Direct (VLESS)",       "147.45.252.234", 2096),
            // General internet
            ("Cloudflare DNS",          "1.1.1.1",       443),
            ("Google DNS",              "8.8.8.8",        53),
            ("Cloudflare (razblokirator)", "104.21.0.1", 443),
        ]

        let udpEndpoints: [(name: String, host: String, port: UInt16)] = [
            ("DE Hysteria2 (UDP)",      "162.19.242.30", 8443),
            ("NL Hysteria2 (UDP)",      "147.45.252.234", 8443),
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
            ("Backend health",       "https://madfrog.online/health"),
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
            let completed = TestCompleteFlag()

            // Timeout after 5 seconds
            queue.asyncAfter(deadline: .now() + 5) {
                if completed.set() { return }
                connection.cancel()
                continuation.resume(returning: (false, 5.0, "TIMEOUT (5s)"))
            }

            connection.stateUpdateHandler = { state in
                guard !completed.isSet else { return }
                switch state {
                case .ready:
                    if completed.set() { return }
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    connection.cancel()
                    continuation.resume(returning: (true, elapsed, ""))
                case .failed(let error):
                    if completed.set() { return }
                    connection.cancel()
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    continuation.resume(returning: (false, elapsed, error.localizedDescription))
                case .cancelled:
                    if completed.set() { return }
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
            let completed = TestCompleteFlag()

            queue.asyncAfter(deadline: .now() + 5) {
                if completed.set() { return }
                connection.cancel()
                continuation.resume(returning: (false, 5.0, "TIMEOUT (5s)"))
            }

            connection.stateUpdateHandler = { state in
                guard !completed.isSet else { return }
                switch state {
                case .ready:
                    // UDP is "connectionless" — send a probe to confirm path
                    connection.send(content: Data([0x00]), completion: .contentProcessed { error in
                        if completed.set() { return }
                        let elapsed = CFAbsoluteTimeGetCurrent() - start
                        connection.cancel()
                        if let error {
                            continuation.resume(returning: (false, elapsed, error.localizedDescription))
                        } else {
                            continuation.resume(returning: (true, elapsed, ""))
                        }
                    })
                case .failed(let error):
                    if completed.set() { return }
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    connection.cancel()
                    continuation.resume(returning: (false, elapsed, error.localizedDescription))
                case .cancelled:
                    if completed.set() { return }
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

/// Single-shot completion flag for the TCP/UDP test closures. NSLock-guarded
/// so Swift 6 strict concurrency lets us share it across the @Sendable
/// callbacks (timeout watchdog + state handler) — same pattern as
/// `ManagedAtomic` in PingService.
private final class TestCompleteFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }
    /// Atomically set true. Returns the previous value — caller uses
    /// `if completed.set() { return }` to guarantee single delivery.
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let prev = done
        done = true
        return prev
    }
}
