import SwiftUI

struct DebugLogsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var tunnelLog = ""
    @State private var stderrLog = ""
    @State private var diagnostics = ""
    @State private var selectedTab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker
                Picker("Log", selection: $selectedTab) {
                    Text("Tunnel").tag(0)
                    Text("stderr").tag(1)
                    Text("Diag").tag(2)
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
}
