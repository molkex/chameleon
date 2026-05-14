import Foundation

/// Detects tunnel stall from REAL user-traffic outcomes — not synthetic
/// probes — by parsing sing-box log lines as they arrive via
/// `ExtensionPlatformInterface.writeLogs`.
///
/// Why this exists (build 44, 2026-04-27): the previous build-42/43
/// `TunnelStallProbe` validated a 32 KB GET to api.madfrog.online via the
/// active outbound and reported "OK" whenever that 32 KB body completed
/// in under 8 s. Field log 2026-04-27 15:14 showed the probe consistently
/// reporting `body=32768B elapsed=946ms` while user connections to
/// facebook.com (157.240.205.35), AWS (13.33.235.x), Cloudflare DoH
/// (1.0.0.1:443) all hit `dial tcp ...: i/o timeout` at the 5 s
/// sing-box default. The probe target reaches via one CDN edge path
/// while real destinations need different routes — synthetic probes lie
/// in this scenario, by design.
///
/// Codex's verdict (after the false-OK problem was demonstrated): "the
/// only trustworthy ground truth is sing-box's handling of real user
/// flows". This detector implements that. Sing-box already logs every
/// dial error; we read those events and decide STALL based on real
/// outcomes against real destinations.
///
/// Detection formula (sliding 30 s window, applied per evaluation tick):
///
///     attempts        >= 8
///     timeouts        >= 5
///     timeout_rate    >= 0.6           // 60% of attempts failed
///     distinct_dests  >= 3              // not one bad host
///     no_recent_meaningful_download   // suppressed if any conn
///                                       // closed in the last 30 s with
///                                       // downlink >= 4096 bytes
///
/// All criteria must hold simultaneously. Without `distinct_dests` and
/// `no_recent_meaningful_download` a single broken host would trigger
/// false-positive STALL. Without `timeouts >= 5` plus `attempts >= 8`,
/// idle browsing (zero attempts) would never trigger but neither would
/// sparse failures during real outage.
///
/// Detection latency: 6-15 s during active browsing. The first `dial
/// tcp ...: i/o timeout` arrives ~5 s after sing-box's dial deadline;
/// the formula needs 5 of those, so 5×~5s in the worst sequential case,
/// faster when iOS opens connections in parallel (typical Safari fetches
/// 6-8 hosts simultaneously per page).
///
/// Memory: ~100 events × ~80 bytes = ~8 KB ring buffer. Inside a
/// PacketTunnel extension's 50 MB jetsam cap this is rounding.
///
/// Apple Review: this is in-process processing of our own VPN's traffic
/// metadata. No tracking, no analytics, no data leaving the extension.
/// Same `LibboxCommandClient.writeLogs` API used by every sing-box-based
/// VPN app on the App Store (Karing, Hiddify, FlClash). App Store
/// Review Guideline 4.5.4 explicitly expects VPN apps to "function
/// properly" — detecting and recovering from broken paths is exactly
/// that.
final class RealTrafficStallDetector {

    // MARK: - Configuration

    struct Config {
        /// Sliding window size — events older than this are dropped from
        /// the ring buffer before evaluation. 30 s gives enough events
        /// during real browsing without holding stale data.
        var windowSeconds: TimeInterval = 30

        /// Minimum total dial attempts in window before STALL can fire.
        /// Without this an idle tunnel (no traffic) would oscillate
        /// between "0 attempts / 0 failures = stall?" decisions.
        var minAttempts: Int = 8

        /// Minimum failed dials (i/o timeout / context deadline / TLS
        /// timeout) in window. Need a real cluster, not one transient
        /// blip on a single host.
        var minTimeouts: Int = 5

        /// Failure ratio required. 0.6 = 60% of attempts failed.
        /// Excludes scenarios where a few hosts time out among many
        /// successful connections (e.g. one slow CDN, rest fine).
        var minTimeoutRate: Double = 0.6

        /// Distinct destination IPs required among failures. Excludes
        /// "one bad host" scenarios — if 5 timeouts all hit the same
        /// IP, that's host-specific, not tunnel-wide.
        var minDistinctDestinations: Int = 3

        /// If any connection closed in the window with at least this
        /// many downlink bytes, suppress STALL — meaningful download
        /// proves the tunnel is moving real data.
        var meaningfulDownloadBytes: Int64 = 4096

        /// Cooldown after firing STALL before we'll fire another. Gives
        /// sing-box and the main app's fallback handler time to react
        /// before we re-trigger.
        var cooldownAfterFallback: TimeInterval = 90

        /// Per-hour cap. Real-network outages sometimes flap; we don't
        /// want to thrash UI/connections more than this many times.
        var maxFallbacksPerHour: Int = 6
    }

    // MARK: - Event types

    /// One observation parsed from a sing-box log line. The pure parsing
    /// + windowing + STALL formula live in `RealTrafficStallLogic`
    /// (under Shared/, so they're unit-testable); this detector owns the
    /// queue, ring buffers, cooldown / per-hour bookkeeping and the
    /// `onStall` callback.
    private typealias DialAttempt = RealTrafficStallLogic.DialAttempt
    private typealias ConnectionClose = RealTrafficStallLogic.ConnectionClose

    // MARK: - State

    private let config: Config
    private let onStall: (Date) -> Void

    /// Serial queue protects buffers — `writeLogs` may be invoked from
    /// arbitrary libbox-internal goroutines, all funneled through here
    /// so we never read mid-mutation.
    private let queue = DispatchQueue(label: "com.madfrog.vpn.realstall", qos: .utility)

    private var dialEvents: [DialAttempt] = []
    private var closeEvents: [ConnectionClose] = []
    private var lastFallbackAt: Date?
    private var fallbacksInLastHour: [Date] = []
    private var lastEvaluationAt: Date?

    /// Rate-limit evaluation — we don't need to recompute on every log
    /// line. Once per second is plenty given window=30s and min=8 events.
    private static let evaluationInterval: TimeInterval = 1

    // MARK: - Lifecycle

    init(config: Config = Config(), onStall: @escaping (Date) -> Void) {
        self.config = config
        self.onStall = onStall
        TunnelFileLogger.log(
            "RealTrafficStallDetector: init window=\(Int(config.windowSeconds))s minAttempts=\(config.minAttempts) minTimeouts=\(config.minTimeouts) rate=\(config.minTimeoutRate)",
            category: "real-stall"
        )
    }

    // MARK: - Log line ingestion

    /// Called from `ExtensionPlatformInterface.writeLogs` for every
    /// sing-box log message. Cheap fast-path: only strings that look
    /// like dial events or connection closes get parsed; everything
    /// else is rejected by simple substring tests before regex.
    func ingest(level: Int32, message: String) {
        // Dispatch to serial queue so the parser doesn't block libbox's
        // log-emission thread and the ring buffers stay consistent.
        let now = Date()
        queue.async { [weak self] in
            self?.process(level: level, message: message, at: now)
        }
    }

    private func process(level: Int32, message: String, at now: Date) {
        // Fast-path filters — most messages are benign and should be
        // skipped without any allocation. Each line ~100 bytes; we get
        // thousands per minute from sing-box at INFO level.

        // Build-44.1: real user-dial failures from sing-box look like:
        //   "connection: open connection to 95.161.76.100:5222 using outbound/vless[de-direct-de]: dial tcp 162.19.242.30:443: i/o timeout"
        //   "connection: open connection to 23.3.91.165:443 using outbound/vless[de-direct-de]: read tcp <src>-><dst>: read: operation timed out"
        //
        // The "outbound/<type>[<tag>]:" anchor identifies which leaf
        // failed; "open connection to <USER_DEST>:" gives the actual
        // destination the user was trying to reach (so distinct_dests
        // counts hosts). NOTE: lines also contain ANSI colour escapes
        // ("\u{1b}[31mERROR\u{1b}[0m") AND connection-id markers
        // ("[[38;5;101m1915784021[0m 2m7s]") — both of which have stray
        // square brackets that previously fooled the bracket-pair
        // outbound parser. Anchoring on "using outbound/" sidesteps
        // that entirely.
        if RealTrafficStallLogic.isUserDialFailureLine(message) {
            if let dial = RealTrafficStallLogic.parseUserDialFailure(from: message, at: now) {
                addDialAttempt(dial)
                evaluateIfDue(at: now)
            }
            return
        }

        // Successful USER dials. Sing-box logs them as:
        //   "outbound/vless[de-direct-de]: outbound connection to 142.X.Y.Z:443"
        // on the leaf line itself. We use these to bound the failure
        // ratio denominator (so a tunnel that sees both successes and
        // failures isn't flagged as STALL).
        if RealTrafficStallLogic.isDialSuccessLine(message) {
            if let success = RealTrafficStallLogic.parseDialSuccess(from: message, at: now) {
                addDialAttempt(success)
                evaluateIfDue(at: now)
            }
            return
        }

        // Build-44.1: removed the broad "connection upload finished" /
        // "download finished" suppressor. It triggered on EVERY closed
        // connection regardless of whether real bytes flowed, which
        // suppressed legitimate STALLs on the field test 2026-04-27
        // 16:17 (6 synthetic-probe FAIL streaks, 0 RealTraffic STALLs,
        // because every tiny TLS-aborted connection still emitted an
        // "upload finished" line and reset the suppressor). With a
        // proper bytes counter we'd distinguish, but the log format
        // doesn't carry bytes here. Better to rely on the failure-
        // ratio criterion (60% of attempts must be timeouts) — if
        // real data was flowing somewhere, the ratio falls below the
        // threshold naturally.
    }

    // MARK: - State updates (queue-confined)

    private func addDialAttempt(_ event: DialAttempt) {
        // Drop expired before insert so the buffer is always bounded.
        dialEvents = RealTrafficStallLogic.pruned(
            dialEvents, windowSeconds: config.windowSeconds,
            referenceDate: event.timestamp, timestamp: { $0.timestamp }
        )
        dialEvents.append(event)
    }

    private func addCloseEvent(_ event: ConnectionClose) {
        closeEvents = RealTrafficStallLogic.pruned(
            closeEvents, windowSeconds: config.windowSeconds,
            referenceDate: event.timestamp, timestamp: { $0.timestamp }
        )
        closeEvents.append(event)
    }

    // MARK: - Evaluation

    private func evaluateIfDue(at now: Date) {
        if let last = lastEvaluationAt, now.timeIntervalSince(last) < Self.evaluationInterval {
            return
        }
        lastEvaluationAt = now

        // Cooldown — don't re-fire while sing-box / main app are still
        // adjusting from the last STALL.
        if let lastFallback = lastFallbackAt,
           now.timeIntervalSince(lastFallback) < config.cooldownAfterFallback {
            return
        }

        // Per-hour cap.
        let oneHourAgo = now.addingTimeInterval(-3600)
        fallbacksInLastHour.removeAll { $0 < oneHourAgo }
        if fallbacksInLastHour.count >= config.maxFallbacksPerHour {
            return
        }

        let recentDials = RealTrafficStallLogic.pruned(
            dialEvents, windowSeconds: config.windowSeconds,
            referenceDate: now, timestamp: { $0.timestamp }
        )
        let recentCloses = RealTrafficStallLogic.pruned(
            closeEvents, windowSeconds: config.windowSeconds,
            referenceDate: now, timestamp: { $0.timestamp }
        )

        let thresholds = RealTrafficStallLogic.Thresholds(
            minAttempts: config.minAttempts,
            minTimeouts: config.minTimeouts,
            minTimeoutRate: config.minTimeoutRate,
            minDistinctDestinations: config.minDistinctDestinations,
            meaningfulDownloadBytes: config.meaningfulDownloadBytes
        )
        let decision = RealTrafficStallLogic.evaluate(
            recentDials: recentDials, recentCloses: recentCloses, thresholds: thresholds
        )
        guard decision == .stall else { return }

        // All criteria met — fire STALL.
        lastFallbackAt = now
        fallbacksInLastHour.append(now)
        let timeouts = recentDials.filter { $0.isTimeout }.count
        let rate = recentDials.isEmpty ? 0 : Double(timeouts) / Double(recentDials.count)
        TunnelFileLogger.log(
            "RealTrafficStallDetector: STALL attempts=\(recentDials.count) timeouts=\(timeouts) rate=\(String(format: "%.2f", rate)) closesWithDownload=\(recentCloses.count)",
            category: "real-stall"
        )
        onStall(now)
    }
}
