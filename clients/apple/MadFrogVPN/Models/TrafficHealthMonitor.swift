import Foundation
import Network

/// Health probe running in the main app whenever the VPN tunnel is up.
/// Issues a small HTTPS GET to Apple's captive-portal endpoint on every
/// `probeInterval`; on `stallThreshold` consecutive failures it calls
/// `onStallDetected`, which is expected to perform a fallback (switch
/// leg / country / Auto).
///
/// Why this matters: sing-box's own urltest decides whether a leg is alive
/// based on a single HEAD probe to gstatic.com running periodically. That
/// signal is fine for "should I prefer A over B at startup?" but not for
/// "the user picked DE and DE just started silently dropping packets" —
/// urltest only re-elects when its interval fires, not when traffic stalls.
/// This monitor is the missing piece, modelled after Cloudflare WARP and
/// ProtonVPN's connection guard.
///
/// Build-39 (2026-04-26): the foreground-only `isAppActive` gate was
/// removed. The original rationale ("don't burn battery on speculative
/// URLSession tasks while the user isn't watching") inverted the actual
/// failure mode: stall detection only matters when the user IS using the
/// network — the only window where the gate also paused us. The PacketTunnel
/// extension now hosts an identical probe (`TunnelStallProbe`) so detection
/// keeps running even when iOS suspends the main app entirely; this
/// main-app monitor is now defense-in-depth for the foreground window.
///
/// Apple-friendly choices:
/// - Probe target is `captive.apple.com`, the same endpoint iOS itself
///   uses for connectivity detection. App Review can't object.
/// - Honours a user toggle (`isUserEnabled`) — Settings → Auto-recover.
/// - Hard caps fallback frequency (cooldown + per-hour limit) so a
///   genuinely broken environment doesn't trigger reconnect storms.
@MainActor
final class TrafficHealthMonitor {
    /// Inputs from the calling context.
    struct Dependencies {
        var isVPNConnected: () -> Bool
        var isCommandClientConnected: () -> Bool
        var isAppActive: () -> Bool
        var isUserEnabled: () -> Bool
        var probe: (URL, TimeInterval) async -> ProbeResult
        var onStallDetected: () async -> Void
        /// Build-35: notified after every probe success. AppState uses this
        /// to record "leg X worked on network Y for country Z" into the
        /// per-network memory, so subsequent connects bypass the race.
        /// Optional — preserves test-fixture compatibility.
        var onProbeSuccess: (() async -> Void)?
        var log: (String) -> Void
    }

    enum ProbeResult: Equatable {
        case success
        case failure(reason: String)
    }

    /// Tunable intervals. Defaults match the Cloudflare WARP guard
    /// (~10s interval, ~4s probe budget). Keep these as `let` so a unit
    /// test can override via the constructor and run in compressed time.
    let probeInterval: Duration
    let firstProbeDelay: Duration    // delay before the very first probe at start()
    let probeTimeoutSeconds: TimeInterval
    let cooldownAfterFallback: Duration
    let suspendAfterManualSwitch: Duration
    let stallThreshold: Int          // consecutive failures to trigger fallback
    let maxFallbacksPerHour: Int

    private let deps: Dependencies
    private let probeURL: URL

    private var task: Task<Void, Never>?
    /// Wall-clock timestamps so cooldowns survive scenePhase transitions
    /// without us having to maintain an internal Duration counter that
    /// only advances while the loop is running.
    private var lastFallbackAt: Date?
    private var suspendUntil: Date?
    private var consecutiveFailures = 0
    private var fallbacksInLastHour: [Date] = []

    init(
        probeURL: URL = URL(string: "https://captive.apple.com/hotspot-detect.html")!,
        probeInterval: Duration = .seconds(10),
        firstProbeDelay: Duration = .seconds(3),
        probeTimeoutSeconds: TimeInterval = 4.0,
        cooldownAfterFallback: Duration = .seconds(60),
        suspendAfterManualSwitch: Duration = .seconds(5),
        stallThreshold: Int = 2,
        maxFallbacksPerHour: Int = 5,
        dependencies: Dependencies
    ) {
        self.probeURL = probeURL
        self.probeInterval = probeInterval
        self.firstProbeDelay = firstProbeDelay
        self.probeTimeoutSeconds = probeTimeoutSeconds
        self.cooldownAfterFallback = cooldownAfterFallback
        self.suspendAfterManualSwitch = suspendAfterManualSwitch
        self.stallThreshold = stallThreshold
        self.maxFallbacksPerHour = maxFallbacksPerHour
        self.deps = dependencies
    }

    deinit {
        task?.cancel()
    }

    /// Start the periodic probe loop. Idempotent — calling start while
    /// a loop is running is a no-op.
    func start() {
        if task != nil { return }
        deps.log("TrafficHealthMonitor: start")
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Stop the probe loop. Failure counters are reset so the next
    /// start() is a clean slate.
    func stop() {
        task?.cancel()
        task = nil
        consecutiveFailures = 0
        deps.log("TrafficHealthMonitor: stop")
    }

    /// Suppress probing for a short window after a manual server switch
    /// or a network transition. Prevents the monitor from fighting with
    /// the user/sing-box during settle time.
    func suspendForManualSwitch() {
        suspendUntil = Date().addingTimeInterval(toSeconds(suspendAfterManualSwitch))
        consecutiveFailures = 0
        deps.log("TrafficHealthMonitor: suspended until \(suspendUntil!)")
    }

    private func runLoop() async {
        // Run the first probe quickly (default ~3s) to catch a misrouted
        // initial leg before the user even sees a stalled page load. After
        // that, fall back to the steady-state interval.
        try? await Task.sleep(for: firstProbeDelay)
        if Task.isCancelled { return }
        await tickIfEligible()
        while !Task.isCancelled {
            try? await Task.sleep(for: probeInterval)
            if Task.isCancelled { break }
            await tickIfEligible()
        }
    }

    /// Public so unit tests can drive a single iteration without waiting
    /// on the Task.sleep loop.
    func tickIfEligible() async {
        guard deps.isUserEnabled() else { return }
        // Build-39: isAppActive gate removed. See class doc.
        guard deps.isVPNConnected() else {
            // Tunnel is down — nothing for us to recover. Reset failure
            // counter so a future reconnect doesn't inherit stale state.
            consecutiveFailures = 0
            return
        }
        if let until = suspendUntil, Date() < until { return }
        if let last = lastFallbackAt, Date().timeIntervalSince(last) < toSeconds(cooldownAfterFallback) {
            return
        }
        // Trim the per-hour window before checking the cap.
        let oneHourAgo = Date().addingTimeInterval(-3600)
        fallbacksInLastHour.removeAll { $0 < oneHourAgo }
        if fallbacksInLastHour.count >= maxFallbacksPerHour {
            deps.log("TrafficHealthMonitor: hourly cap reached, idle")
            return
        }

        let result = await deps.probe(probeURL, probeTimeoutSeconds)
        switch result {
        case .success:
            if consecutiveFailures > 0 {
                deps.log("TrafficHealthMonitor: probe OK (after \(consecutiveFailures) misses)")
            }
            consecutiveFailures = 0
            if let onSuccess = deps.onProbeSuccess {
                await onSuccess()
            }
        case .failure(let reason):
            consecutiveFailures += 1
            deps.log("TrafficHealthMonitor: probe FAIL #\(consecutiveFailures) — \(reason)")
            if consecutiveFailures >= stallThreshold {
                let now = Date()
                lastFallbackAt = now
                fallbacksInLastHour.append(now)
                consecutiveFailures = 0
                deps.log("TrafficHealthMonitor: STALL — invoking fallback")
                await deps.onStallDetected()
            }
        }
    }

    private func toSeconds(_ d: Duration) -> TimeInterval {
        let comps = d.components
        return TimeInterval(comps.seconds) + TimeInterval(comps.attoseconds) / 1e18
    }
}

// MARK: - Default URLSession probe

/// Default real-world probe against `captive.apple.com`. Counts the response
/// as success only when the HTTP status is 2xx **and** the body matches the
/// Apple sentinel — mitigates a captive-portal-style middlebox returning
/// 200 with a login page.
///
/// Sentinel: `<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>`
/// We only check for "Success" substring to be tolerant of trailing whitespace
/// or charset variations.
enum HealthProbeURLSession {
    static func probe(url: URL, timeout: TimeInterval) async -> TrafficHealthMonitor.ProbeResult {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        // Defensive headers: some captive portals key off User-Agent for
        // their interception. iOS itself uses CaptiveNetworkSupport but
        // we want consistent behaviour.
        request.setValue("MadFrog-HealthCheck/1.0", forHTTPHeaderField: "User-Agent")
        request.httpMethod = "GET"

        let session: URLSession = {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout + 1
            // Don't piggy-back on shared cookies/cache — clean probe each time.
            config.httpCookieAcceptPolicy = .never
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            return URLSession(configuration: config)
        }()

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(reason: "no http response")
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(reason: "status \(http.statusCode)")
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("Success") {
                return .success
            }
            return .failure(reason: "body mismatch (len \(data.count))")
        } catch {
            return .failure(reason: error.localizedDescription)
        }
    }
}
