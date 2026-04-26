import Foundation
import Libbox

/// Stall detector that runs INSIDE the PacketTunnel extension. Unlike the
/// main-app `TrafficHealthMonitor` (which iOS suspends when the app is
/// backgrounded), this probe stays alive as long as the tunnel itself is
/// alive — exactly the window when stall detection actually matters: the
/// user opens Safari, MadFrog goes background, traffic stalls on a dead
/// leaf, and there's nobody to notice except the extension.
///
/// Probes the live tunnel via `captive.apple.com/hotspot-detect.html`
/// (same endpoint iOS itself uses for connectivity detection — App-Review-
/// safe; reuses the exact target main-app `HealthProbeURLSession` already
/// uses, so the recovery surface is identical from background and
/// foreground).
///
/// On 2 consecutive failures (build-39 default) it:
///   1. Logs a `STALL` line to `tunnel-debug.log` so the next field test
///      can verify the probe fired.
///   2. Writes the current wall-clock to App Group UserDefaults at
///      `AppConstants.tunnelStallRequestedAtKey`. The main app reads this
///      on every foreground transition and on its own probe tick — if the
///      timestamp is newer than the last fallback it ran, AppState
///      invokes `performFallbackForCurrentLeg()` synchronously to switch
///      the active leg.
///   3. Best-effort: tries to call `LibboxCommandClient.urlTest(group)` on
///      every urltest group it knows about, forcing sing-box to re-probe
///      every member immediately instead of waiting for the next 10s
///      tick. Combined with the build-39 backend `tolerance: 0`, this
///      makes the new winner visible within 1-2 seconds even if the main
///      app is suspended.
///
/// Apple-friendly choices:
/// - Probe target is `captive.apple.com`, the same endpoint iOS uses for
///   hotspot detection. App Review can't object.
/// - Hard caps fallback frequency (per-fallback cooldown + per-hour
///   limit) so a genuinely broken environment doesn't trigger reconnect
///   storms or burn the user's data plan.
/// - Probe overhead: one HTTP GET (~1 KB) every 10 seconds = ~36 KB/hour.
///   Well under any data-cost concern even on metered LTE.
final class TunnelStallProbe {

    // MARK: - Configuration

    struct Config {
        var probeURL: URL = URL(string: "https://captive.apple.com/hotspot-detect.html")!
        var firstProbeDelay: TimeInterval = 3
        var probeInterval: TimeInterval = 10
        var probeTimeout: TimeInterval = 4
        var stallThreshold: Int = 2
        var cooldownAfterFallback: TimeInterval = 60
        var maxFallbacksPerHour: Int = 5

        /// Names of urltest groups to nudge via `LibboxCommandClient.urlTest`
        /// when stall fires. Sing-box's group tags are the human-facing
        /// labels we generate in `backend/internal/vpn/clientconfig.go`.
        var urltestGroupTags: [String] = ["Auto", "🇩🇪 Германия", "🇳🇱 Нидерланды"]
    }

    // MARK: - State

    private let config: Config
    private var task: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var lastFallbackAt: Date?
    private var fallbacksInLastHour: [Date] = []

    // MARK: - Lifecycle

    init(config: Config = Config()) {
        self.config = config
    }

    func start() {
        guard task == nil else { return }
        TunnelFileLogger.log("TunnelStallProbe: start interval=\(Int(config.probeInterval))s threshold=\(config.stallThreshold)", category: "tunnel-probe")
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        consecutiveFailures = 0
        TunnelFileLogger.log("TunnelStallProbe: stop", category: "tunnel-probe")
    }

    // MARK: - Probe loop

    private func runLoop() async {
        // Run the first probe quickly so a misrouted initial leg is caught
        // before the user even sees a stalled page load.
        try? await Task.sleep(for: .seconds(config.firstProbeDelay))
        if Task.isCancelled { return }
        await tickIfEligible()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(config.probeInterval))
            if Task.isCancelled { break }
            await tickIfEligible()
        }
    }

    /// Internal so a unit test can drive a single iteration without
    /// waiting on Task.sleep. (Hooks for testing live in tests target.)
    func tickIfEligible() async {
        // Cooldown after recent fallback — let sing-box settle before we
        // declare a new stall.
        if let last = lastFallbackAt, Date().timeIntervalSince(last) < config.cooldownAfterFallback {
            return
        }
        // Trim per-hour window before checking the cap.
        let oneHourAgo = Date().addingTimeInterval(-3600)
        fallbacksInLastHour.removeAll { $0 < oneHourAgo }
        if fallbacksInLastHour.count >= config.maxFallbacksPerHour {
            return
        }

        let ok = await probe()
        if ok {
            if consecutiveFailures > 0 {
                TunnelFileLogger.log("TunnelStallProbe: probe OK (after \(consecutiveFailures) misses)", category: "tunnel-probe")
            }
            consecutiveFailures = 0
            return
        }
        consecutiveFailures += 1
        TunnelFileLogger.log("TunnelStallProbe: probe FAIL #\(consecutiveFailures)", category: "tunnel-probe")
        if consecutiveFailures >= config.stallThreshold {
            let now = Date()
            lastFallbackAt = now
            fallbacksInLastHour.append(now)
            consecutiveFailures = 0
            TunnelFileLogger.log("TunnelStallProbe: STALL — invoking fallback", category: "tunnel-probe")
            invokeFallback(at: now)
        }
    }

    // MARK: - Probe

    private func probe() async -> Bool {
        var request = URLRequest(
            url: config.probeURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: config.probeTimeout
        )
        request.setValue("MadFrog-StallProbe/1.0", forHTTPHeaderField: "User-Agent")
        request.httpMethod = "GET"

        let session: URLSession = {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = config.probeTimeout
            cfg.timeoutIntervalForResource = config.probeTimeout + 1
            cfg.httpCookieAcceptPolicy = .never
            cfg.urlCache = nil
            cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            return URLSession(configuration: cfg)
        }()

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return false
            }
            // Apple sentinel: <HTML><HEAD><TITLE>Success</TITLE>...
            // Match a "Success" substring to be tolerant of trailing
            // whitespace or charset variants. Captive portals returning
            // 200 with a login page won't match.
            let body = String(data: data, encoding: .utf8) ?? ""
            return body.contains("Success")
        } catch {
            return false
        }
    }

    // MARK: - Fallback invocation

    private func invokeFallback(at now: Date) {
        // 1. Cross-process flag — main app picks this up on next foreground
        //    or on its own TrafficHealthMonitor tick and fires
        //    performFallbackForCurrentLeg().
        let defaults = UserDefaults(suiteName: AppConstants.appGroupID)
        defaults?.set(now.timeIntervalSince1970, forKey: AppConstants.tunnelStallRequestedAtKey)
        TunnelFileLogger.log("TunnelStallProbe: signalled main app via shared defaults", category: "tunnel-probe")

        // 2. Best-effort: nudge sing-box urltest groups to re-probe NOW
        //    (rather than waiting up to 10s for the next tick). Even if
        //    we can't drive a Libbox CommandClient from this process,
        //    the cross-process flag in (1) is enough — it just takes one
        //    main-app tick longer.
        nudgeUrltestGroups()
    }

    /// Force sing-box to re-probe every urltest group immediately. Best
    /// effort: failures are logged but don't block the fallback flag.
    /// Implementation intentionally creates a short-lived CommandClient
    /// each time — the connection lives <1s.
    private func nudgeUrltestGroups() {
        let handler = NudgeHandler()
        let options = LibboxCommandClientOptions()
        options.statusInterval = Int64(NSEC_PER_SEC)

        guard let client = LibboxNewCommandClient(handler, options) else {
            TunnelFileLogger.log("TunnelStallProbe: nudge skipped — LibboxNewCommandClient nil", category: "tunnel-probe")
            return
        }

        do {
            try client.connect()
        } catch {
            TunnelFileLogger.log("TunnelStallProbe: nudge connect failed (\(error.localizedDescription))", category: "tunnel-probe")
            return
        }

        defer { try? client.disconnect() }

        for group in config.urltestGroupTags {
            do {
                try client.urlTest(group)
                TunnelFileLogger.log("TunnelStallProbe: urlTest('\(group)') OK", category: "tunnel-probe")
            } catch {
                TunnelFileLogger.log("TunnelStallProbe: urlTest('\(group)') FAILED \(error.localizedDescription)", category: "tunnel-probe")
            }
        }

        // closeConnections forces in-flight TCP streams (which were stuck
        // on the dead leaf) to terminate, so they reconnect through whichever
        // member sing-box's freshly re-probed urltest now picks.
        do {
            try client.closeConnections()
            TunnelFileLogger.log("TunnelStallProbe: closeConnections OK", category: "tunnel-probe")
        } catch {
            TunnelFileLogger.log("TunnelStallProbe: closeConnections FAILED \(error.localizedDescription)", category: "tunnel-probe")
        }
    }
}

// MARK: - LibboxCommandClient handler stub

/// Minimal LibboxCommandClientHandlerProtocol implementation — the nudge
/// flow only calls send-side commands (`urlTest`, `closeConnections`) and
/// disconnects, so we don't need to react to any server callbacks.
private final class NudgeHandler: NSObject, LibboxCommandClientHandlerProtocol, @unchecked Sendable {
    func connected() {}
    func disconnected(_ message: String?) {}
    func setDefaultLogLevel(_ level: Int32) {}
    func clearLogs() {}
    func initializeClashMode(_ modeList: (any LibboxStringIteratorProtocol)?, currentMode: String?) {}
    func updateClashMode(_ newMode: String?) {}
    func write(_ events: LibboxConnectionEvents?) {}
    func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {}
    func writeStatus(_ message: LibboxStatusMessage?) {}
    func writeGroups(_ message: (any LibboxOutboundGroupIteratorProtocol)?) {}
}
