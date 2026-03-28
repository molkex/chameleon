import Foundation
import Network
import CoreTelephony
import UIKit

/// Collects diagnostics data and sends to backend for service improvement.
/// All data is anonymous — no personal info, only technical metrics.
@Observable
final class TelemetryService {
    static let shared = TelemetryService()

    private let endpoint = "\(AppConstants.baseURL)/api/mobile/telemetry"
    private var lastSentAt: Date?
    private let minInterval: TimeInterval = 300 // 5 min between sends

    /// Cached real IP (fetched once per app launch).
    private var cachedRealIP: String?
    private var ipFetchTask: Task<String?, Never>?

    /// Event log — flushed on each send.
    private var events: [[String: Any]] = []
    private let eventsLock = NSLock()

    /// Speed test result (bytes/sec download).
    private var lastSpeedTestResult: Int?

    // MARK: - Real IP

    /// Fetch real IP address (before VPN). Call once on app launch.
    func fetchRealIP() {
        guard cachedRealIP == nil, ipFetchTask == nil else { return }
        ipFetchTask = Task {
            let ip = await resolveIP()
            await MainActor.run { cachedRealIP = ip }
            return ip
        }
    }

    private func resolveIP() async -> String? {
        guard let url = URL(string: "https://ipinfo.io/ip") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ip.isEmpty else { return nil }
        return ip
    }

    // MARK: - Event Tracking

    /// Track a user event (screen view, tap, server switch, etc.).
    func trackEvent(_ name: String, params: [String: Any] = [:]) {
        var event: [String: Any] = [
            "name": name,
            "ts": Int(Date().timeIntervalSince1970)
        ]
        for (k, v) in params { event[k] = v }
        eventsLock.lock()
        events.append(event)
        // Keep max 100 events to prevent memory bloat
        if events.count > 100 { events.removeFirst(events.count - 100) }
        eventsLock.unlock()
    }

    /// Convenience: track screen view.
    func trackScreen(_ screen: String) {
        trackEvent("screen_view", params: ["screen": screen])
    }

    /// Thread-safe flush of accumulated events.
    private func flushEvents() -> [[String: Any]] {
        eventsLock.lock()
        let flushed = events
        events.removeAll()
        eventsLock.unlock()
        return flushed
    }

    // MARK: - Speed Test

    /// Run a simple download speed test (small file from our server).
    func runSpeedTest() async -> Int? {
        guard let url = URL(string: "\(AppConstants.baseURL)/api/mobile/speedtest") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let start = Date()
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResp = response as? HTTPURLResponse,
              httpResp.statusCode == 200 else { return nil }

        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return nil }

        let bytesPerSec = Int(Double(data.count) / elapsed)
        lastSpeedTestResult = bytesPerSec
        return bytesPerSec
    }

    // MARK: - Collect & Send

    /// Collect all available diagnostics and send to backend.
    func collectAndSend(
        username: String?,
        pingResults: [String: Int32] = [:],
        vpnConnected: Bool = false,
        selectedServer: String? = nil,
        connectDuration: TimeInterval? = nil,
        selectedProtocol: String? = nil,
        error: String? = nil
    ) {
        // Rate limit
        if let last = lastSentAt, Date().timeIntervalSince(last) < minInterval {
            return
        }

        Task {
            let report = await buildReport(
                username: username,
                pingResults: pingResults,
                vpnConnected: vpnConnected,
                selectedServer: selectedServer,
                connectDuration: connectDuration,
                selectedProtocol: selectedProtocol,
                error: error
            )
            await send(report)
            await MainActor.run { lastSentAt = Date() }
        }
    }

    // MARK: - Build Report

    private func buildReport(
        username: String?,
        pingResults: [String: Int32],
        vpnConnected: Bool,
        selectedServer: String?,
        connectDuration: TimeInterval?,
        selectedProtocol: String?,
        error: String?
    ) async -> [String: Any] {
        var report: [String: Any] = [
            "ts": Int(Date().timeIntervalSince1970),
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
        ]

        if let username { report["username"] = username }
        if let selectedServer { report["selected_server"] = selectedServer }
        if let connectDuration { report["connect_duration_ms"] = Int(connectDuration * 1000) }
        if let selectedProtocol { report["selected_protocol"] = selectedProtocol }
        if let error { report["error"] = error }

        report["vpn_connected"] = vpnConnected

        // Real IP (pre-VPN)
        if let ip = cachedRealIP {
            report["real_ip"] = ip
        }

        // Device info
        report["device"] = await deviceInfo()

        // Network info
        report["network"] = networkInfo()

        // Carrier info
        report["carrier"] = carrierInfo()

        // Ping results (server tag → ms, -1 = failed)
        if !pingResults.isEmpty {
            report["pings"] = pingResults.mapValues { Int($0) }
        }

        // Speed test result
        if let speed = lastSpeedTestResult {
            report["speed_test_bps"] = speed
        }

        // Battery & thermal
        report["battery"] = await batteryInfo()

        // Flush events
        let flushedEvents = flushEvents()
        if !flushedEvents.isEmpty {
            report["events"] = flushedEvents
        }

        // Locale / region
        report["locale"] = Locale.current.identifier
        report["timezone"] = TimeZone.current.identifier

        return report
    }

    // MARK: - Device Info

    @MainActor
    private func deviceInfo() -> [String: String] {
        var info: [String: String] = [:]
        info["model"] = modelIdentifier()
        info["os"] = UIDevice.current.systemVersion
        info["name"] = UIDevice.current.model // "iPhone" / "iPad"
        return info
    }

    private func modelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce("") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return result }
            return result + String(UnicodeScalar(UInt8(value)))
        }
    }

    // MARK: - Network Info

    private func networkInfo() -> [String: String] {
        var info: [String: String] = [:]

        let monitor = NWPathMonitor()
        let path = monitor.currentPath

        if path.usesInterfaceType(.wifi) {
            info["type"] = "wifi"
        } else if path.usesInterfaceType(.cellular) {
            info["type"] = "cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            info["type"] = "ethernet"
        } else {
            info["type"] = "other"
        }

        info["expensive"] = path.isExpensive ? "true" : "false"
        info["constrained"] = path.isConstrained ? "true" : "false"

        return info
    }

    // MARK: - Carrier Info

    private func carrierInfo() -> [String: String] {
        var info: [String: String] = [:]

        let networkInfo = CTTelephonyNetworkInfo()

        if let carriers = networkInfo.serviceSubscriberCellularProviders {
            for (key, carrier) in carriers {
                if let name = carrier.carrierName {
                    info["carrier_\(key)"] = name
                }
                if let mcc = carrier.mobileCountryCode {
                    info["mcc_\(key)"] = mcc
                }
                if let mnc = carrier.mobileNetworkCode {
                    info["mnc_\(key)"] = mnc
                }
                if let iso = carrier.isoCountryCode {
                    info["country_\(key)"] = iso
                }
            }
        }

        // Current radio access technology (LTE, 5G, etc.)
        if let radioTech = networkInfo.serviceCurrentRadioAccessTechnology {
            for (key, tech) in radioTech {
                let shortTech = tech
                    .replacingOccurrences(of: "CTRadioAccessTechnology", with: "")
                info["radio_\(key)"] = shortTech
            }
        }

        return info
    }

    // MARK: - Battery & Thermal

    @MainActor
    private func batteryInfo() -> [String: Any] {
        UIDevice.current.isBatteryMonitoringEnabled = true
        var info: [String: Any] = [:]
        let level = UIDevice.current.batteryLevel
        if level >= 0 { info["level"] = Int(level * 100) }
        switch UIDevice.current.batteryState {
        case .charging: info["state"] = "charging"
        case .full: info["state"] = "full"
        case .unplugged: info["state"] = "unplugged"
        default: info["state"] = "unknown"
        }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: info["thermal"] = "nominal"
        case .fair: info["thermal"] = "fair"
        case .serious: info["thermal"] = "serious"
        case .critical: info["thermal"] = "critical"
        @unknown default: info["thermal"] = "unknown"
        }
        return info
    }

    // MARK: - Send

    private func send(_ report: [String: Any]) async {
        guard let url = URL(string: endpoint) else { return }
        guard let body = try? JSONSerialization.data(withJSONObject: report) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MadFrog-iOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        // Fire and forget — don't block on response
        _ = try? await URLSession.shared.data(for: request)
    }
}
