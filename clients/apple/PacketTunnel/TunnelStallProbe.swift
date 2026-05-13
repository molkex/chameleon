import Foundation
import Libbox

/// Stall detector that runs INSIDE the PacketTunnel extension. Unlike the
/// main-app `TrafficHealthMonitor` (which iOS suspends when the app is
/// backgrounded), this probe stays alive as long as the tunnel itself is
/// alive — exactly the window when stall detection actually matters: the
/// user opens Safari, MadFrog goes background, traffic stalls on a dead
/// leaf, and there's nobody to notice except the extension.
///
/// Build-42 (2026-04-27): probe target switched from `captive.apple.com`
/// (32-byte body) to our own `/api/v1/mobile/healthcheck` (32 KB body),
/// because RU LTE RKN throttling lets small responses through but stalls
/// sustained flows. The previous probe declared "tunnel healthy" while the
/// real bulk traffic was stuck — sing-box's urltest does HEAD on gstatic
/// (50-byte 204) and has the same blind spot. Validating a 32 KB body
/// forces the probe to actually traverse the throttle.
///
/// On stallThreshold consecutive failures (build-42 default = 3) it:
///   1. Logs a `STALL` line to `tunnel-debug.log` so the next field test
///      can verify the probe fired.
///   2. Writes the current wall-clock to App Group UserDefaults at
///      `AppConstants.tunnelStallRequestedAtKey`. The main app reads this
///      on every foreground transition and on its own probe tick — if the
///      timestamp is newer than the last fallback it ran, AppState
///      invokes `performFallbackForCurrentLeg()` synchronously to switch
///      the active leg via Clash API (NOT via closeConnections — see
///      below for why we removed that).
///   3. Best-effort: calls `LibboxCommandClient.urlTest(group)` on every
///      urltest group, forcing sing-box to re-probe every member
///      immediately instead of waiting for the next 10 s tick. Combined
///      with the build-39 backend `tolerance: 0`, this makes the new
///      winner visible within 1-2 seconds even if the main app is
///      suspended.
///
/// What we REMOVED in build-42: the post-stall `client.closeConnections()`
/// call. Field log 2026-04-27 12:20 confirmed it was actively harmful: the
/// build-41 outer urltest correctly fell back from `_de_leaves` to
/// `_nl_leaves` and 169 user connections were flowing through NL when the
/// stall probe fired (because `nl-via-msk` hit ~4093 ms — over the old 4 s
/// probeTimeout). `closeConnections()` then killed those NL connections
/// globally; sing-box took ~53 s to re-establish probes through both
/// groups, leaving the user staring at "ничего не грузит" for ~1 minute
/// while the tunnel was actually working perfectly. The build-40
/// `interrupt_exist_connections=true` flag on every urltest+selector
/// already does surgical cleanup whenever sing-box re-elects an outbound,
/// so the global close was redundant on top of being destructive.
///
/// Apple-friendly choices:
/// - Probe target is our own HTTPS endpoint with no auth, no identifiers,
///   no cookies. Apple Review's bar for VPN tunnel health checking.
/// - 30 s probe interval × 32 KB = ~3.8 MB/h overhead — comparable to a
///   single static asset on a normal browsing session.
/// - Hard caps fallback frequency (per-fallback cooldown + per-hour
///   limit) so a genuinely broken environment doesn't trigger reconnect
///   storms or burn the user's data plan.
final class TunnelStallProbe {

    // MARK: - Configuration

    struct Config {
        /// Probe target. Build-42: our own /healthcheck endpoint (32 KB
        /// body) instead of captive.apple.com (32 bytes) so we can detect
        /// RU LTE bulk-throttle scenarios that pass small responses but
        /// stall real flows.
        var probeURL: URL = URL(string: AppConstants.mobileHealthcheckURL)!
        var firstProbeDelay: TimeInterval = 5
        /// 30 s × 32 KB = ~3.8 MB/hour. Apple-Review-acceptable for a VPN
        /// tunnel health probe. Can be tightened to 15 s on a future build
        /// if 30 s recovery feels sluggish.
        var probeInterval: TimeInterval = 15
        /// 8 s gives breathing room above the worst observed `nl-via-msk`
        /// latency (~4 s on RU LTE). Old 4 s value caused false-positive
        /// STALLs on the slow-but-working relay path.
        var probeTimeout: TimeInterval = 8
        /// 3 consecutive failures × 30 s interval ≈ 90 s before fallback
        /// fires. Wide enough to absorb transient network blips and
        /// LTE→Wi-Fi handover, narrow enough to recover from real outages
        /// in under 2 minutes.
        var stallThreshold: Int = 2
        /// Body length floor for a probe to count as "OK". RU LTE RKN
        /// throttles bulk flows but lets small chunks through, so we need
        /// to actually receive most of the 32 KB body. 16 KB is half the
        /// payload — enough to confirm the path can sustain real traffic.
        var minProbeBodyBytes: Int = 16 * 1024
        /// Build 57 (2026-05-13): time-budget for a healthy probe. Field log
        /// 5:48 PM LTE showed the 32 KB body completing in 1.3-1.6 seconds
        /// (= 20-25 KB/s) while Speedtest timed out and Telegram media
        /// stalled. Build 42-56 only checked bytes-received; this elapsed
        /// budget catches DPI throttle that lets bulk through slowly.
        /// 1000 ms / 32 KB = 32 KB/s floor — well below any healthy leg
        /// (worst observed healthy: 396 ms / 32 KB = 83 KB/s).
        var maxProbeElapsedMs: Int = 1000
        var cooldownAfterFallback: TimeInterval = 120
        var maxFallbacksPerHour: Int = 5
        /// Build 57: re-enable active fallback. Build-44 disabled this and
        /// delegated to RealTrafficStallDetector. That worked for kill
        /// scenarios (real-traffic errors visible in singbox log) but is
        /// blind to throttle (no errors logged — just slow). The throttle-
        /// aware probe needs to drive switches itself.
        var activeFallbackEnabled: Bool = true

        /// Names of urltest groups to nudge via `LibboxCommandClient.urlTest`
        /// when stall fires. Sing-box's group tags are the human-facing
        /// labels we generate in `backend/internal/vpn/clientconfig.go`.
        /// Build-41 added nested urltest groups (`_de_leaves`, `_nl_leaves`)
        /// for cross-country fallback — we nudge the user-visible OUTER
        /// groups, sing-box recurses into the inner ones automatically.
        var urltestGroupTags: [String] = ["Auto", "🇩🇪 Германия", "🇳🇱 Нидерланды"]
    }

    // MARK: - State

    /// Mutable so apply(_:) can retune cadence + threshold in response to
    /// NWPathMonitor signals from ExtensionPlatformInterface (Phase 1.C).
    /// The probe loop reads `config.probeInterval` per-iteration, so a
    /// mid-flight swap takes effect on the very next tick (no restart).
    private var config: Config
    private var task: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var lastFallbackAt: Date?
    private var fallbacksInLastHour: [Date] = []
    /// Build 62: tracked profile state so we log only on *transition*,
    /// not on every pathUpdate. iOS fires pathUpdateHandler many times
    /// per minute on a stable cellular path (route refresh, neighbor
    /// discovery, BSSID flap on Wi-Fi), and re-emitting the same line
    /// turned the log into noise. `currentProfile == nil` only before
    /// the first apply, so the very first profile selection is always
    /// logged with an explicit "(initial)" marker.
    private var currentProfile: Profile?

    /// Test-only accessor for the current config snapshot — used by
    /// `TunnelStallProbeProfileTests` to assert that profile switches
    /// actually mutate the tuneables. Not for production callers.
    var currentConfigForTesting: Config { config }

    /// Lookup the active profile (post-`apply(_:)`). Used by tests to
    /// assert no-op vs transition behaviour.
    var currentProfileForTesting: Profile? { currentProfile }

    // MARK: - Profile (Phase 1.C)

    /// Probe profile = tuneable preset selected by network-type signal.
    /// `Profile` lives on the type (not as a free enum) so callers from
    /// other files reference it as `TunnelStallProbe.Profile`.
    enum Profile: String, Equatable {
        /// `NWPath.isExpensive == false`. Wider hysteresis — 2 consecutive
        /// degraded probes at 15 s intervals before fallback. Avoids
        /// false-positive switches on transient Wi-Fi handover blips.
        case wifi
        /// `NWPath.isExpensive == true`. Tight hysteresis — 1 degraded
        /// probe at 5 s intervals before fallback. Field log 2026-05-13
        /// 22:17 LTE: nl-via-msk healthy 502 ms → THROTTLED 5601 ms in
        /// ~90 seconds. Default 2/15 left the user staring at a hang for
        /// 30 s before recovery; this profile recovers in <10 s.
        /// Cost: ~3× probe traffic, ~480 KB / 5 min — negligible.
        case cellular

        var stallThreshold: Int {
            switch self {
            case .wifi: return 2
            case .cellular: return 1
            }
        }
        var probeInterval: TimeInterval {
            switch self {
            case .wifi: return 15
            case .cellular: return 5
            }
        }
    }

    // MARK: - Lifecycle

    init(config: Config = Config()) {
        self.config = config
    }

    /// Apply the named probe profile. No-op if already on that profile —
    /// `pathUpdateHandler` re-fires many times on a stable uplink, so we
    /// dedupe at the log boundary. Transitions emit one line in the form
    /// `profile <from> → <to> (threshold=N, interval=Ms)` so the field log
    /// reads like a narrative: each line is an event, not a heartbeat.
    func apply(_ profile: Profile) {
        if currentProfile == profile {
            return
        }
        let from = currentProfile?.rawValue ?? "initial"
        currentProfile = profile
        config.stallThreshold = profile.stallThreshold
        config.probeInterval = profile.probeInterval
        TunnelFileLogger.log(
            "TunnelStallProbe: profile \(from) → \(profile.rawValue) (threshold=\(profile.stallThreshold), interval=\(Int(profile.probeInterval))s)",
            category: "tunnel-probe"
        )
    }

    func start() {
        guard task == nil else { return }
        let profileLabel = currentProfile?.rawValue ?? "default"
        TunnelFileLogger.log(
            "TunnelStallProbe: start profile=\(profileLabel) threshold=\(config.stallThreshold) interval=\(Int(config.probeInterval))s firstProbeIn=\(Int(config.firstProbeDelay))s",
            category: "tunnel-probe"
        )
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

        let started = Date()
        let (httpOK, bytes) = await probeWithBytes()
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        let rules = TunnelProbeOutcomeRules(
            minBodyBytes: config.minProbeBodyBytes,
            maxElapsedMs: config.maxProbeElapsedMs
        )
        let outcome = rules.evaluate(statusOK: httpOK, bytesReceived: bytes, elapsedMs: elapsedMs)
        let outcomeLabel: String
        switch outcome {
        case .healthy: outcomeLabel = "OK"
        case .throttled(let ms): outcomeLabel = "THROTTLED(\(ms)ms)"
        case .failed(let reason): outcomeLabel = "FAIL(\(reason))"
        }
        // Build-43: log every probe tick with body size + elapsed, regardless
        // of OK/fail. Without this, a 4-minute log buffer truncated past the
        // first STALL window (sing-box is too verbose); we lost ~3 minutes of
        // probe history and could not tell whether build 42 was working as
        // designed. Cost: ~1 line / 15 s = trivial.
        TunnelFileLogger.log("TunnelStallProbe: probe \(outcomeLabel) body=\(bytes)B elapsed=\(elapsedMs)ms", category: "tunnel-probe")
        if !outcome.isDegraded {
            if consecutiveFailures > 0 {
                // Build 62: explicit recovery event. Tells the field log
                // reader "the path self-healed after N degraded probes,
                // no fallback was needed" — without this line we'd see
                // degraded #1 ... degraded #2 ... and then mysteriously
                // never reach the STALL streak, because the OK probe
                // silently reset the counter.
                TunnelFileLogger.log("TunnelStallProbe: probe recovered after \(consecutiveFailures) degraded — counter reset", category: "tunnel-probe")
            }
            consecutiveFailures = 0
            return
        }
        consecutiveFailures += 1
        TunnelFileLogger.log("TunnelStallProbe: probe degraded #\(consecutiveFailures) (\(outcomeLabel))", category: "tunnel-probe")
        // Build 57 (2026-05-13): re-enable active fallback. Build-44 made
        // this passive on the assumption RealTrafficStallDetector (which
        // parses singbox logs for `connection: open ... timeout`) would
        // catch real stalls. That works for KILL scenarios but is BLIND
        // to THROTTLE — DPI throttle delivers full data slowly, no errors
        // in the singbox log. Field log 2026-05-13 5:48 PM confirmed:
        // 32 KB in 1654 ms, no singbox errors, but Speedtest failed and
        // Telegram media stalled. So the throttle-aware probe owns the
        // signal for this class of failure.
        if consecutiveFailures >= config.stallThreshold {
            consecutiveFailures = 0
            if config.activeFallbackEnabled {
                let now = Date()
                lastFallbackAt = now
                fallbacksInLastHour.append(now)
                TunnelFileLogger.log("TunnelStallProbe: STALL streak — invoking fallback (\(outcomeLabel))", category: "tunnel-probe")
                invokeFallback(at: now)
            } else {
                TunnelFileLogger.log("TunnelStallProbe: STALL streak — fallback disabled in config", category: "tunnel-probe")
            }
        }
    }

    // MARK: - Probe

    /// Returns (ok, bytesReceived) so the heartbeat log line can record
    /// how much body we actually got — the difference between "throttle
    /// dropped us at 8 KB" and "TLS handshake failed at 0 B" is the
    /// whole point of the 32 KB endpoint.
    private func probeWithBytes() async -> (Bool, Int) {
        var request = URLRequest(
            url: config.probeURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: config.probeTimeout
        )
        request.setValue("MadFrog-StallProbe/2.0", forHTTPHeaderField: "User-Agent")
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
                return (false, data.count)
            }
            // Throughput-based health check: the backend serves a 32 KB
            // body; we require >= minProbeBodyBytes (16 KB default) to
            // count as OK. RU LTE RKN throttling passes small chunks but
            // stalls sustained flows, so a partial read here = throttled
            // path that sing-box's HEAD-based urltest won't catch.
            return (data.count >= config.minProbeBodyBytes, data.count)
        } catch {
            return (false, 0)
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

    /// Build-49: called by RealTrafficStallDetector's onStall so the extension
    /// can switch outbounds without waiting for the suspended main app.
    func nudgeNow() {
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

        // Build-42: removed `client.closeConnections()` here. Field log
        // 2026-04-27 12:20 showed it killed working NL traffic after the
        // build-41 outer urltest correctly fell back to `_nl_leaves`,
        // causing a self-inflicted ~53 s blackout. The build-40
        // `interrupt_exist_connections=true` flag on every urltest +
        // selector already does surgical cleanup whenever sing-box
        // re-elects an outbound, so the global close was redundant on
        // top of being destructive. Real fallback (when probe says
        // throttled-but-handshaked) flows through:
        //   1. urlTest() above forces sing-box to re-probe — but won't
        //      help if all leaves "look healthy" to its HEAD probe.
        //   2. UserDefaults timestamp signal → main app foreground →
        //      AppState.performFallbackForCurrentLeg() pins a specific
        //      leaf via Clash API. THAT is the authoritative fallback.
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
