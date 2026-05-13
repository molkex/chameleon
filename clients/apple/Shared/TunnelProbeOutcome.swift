import Foundation

/// Classification of a single tunnel-health probe round. Pure data; the
/// PacketTunnel extension's `TunnelStallProbe` does the IO and feeds the
/// result here.
///
/// Build 57 (2026-05-13) — promoted `elapsedMs` to a first-class signal.
/// Pre-build-57 the probe only checked HTTP-status + body length, so DPI
/// throttling that delivered the full 32 KB body in 1.3-1.6 seconds
/// (= 20-25 KB/s) silently reported "OK" while Telegram media and
/// Speedtest visibly failed. Field log 2026-05-13 (5:48 PM LTE) is the
/// motivating evidence — `tunnel-probe: probe OK body=32768B elapsed=1302ms`
/// repeated for 30 seconds, then Speedtest timed out.
///
/// Three outcomes:
///   - `.healthy` — full body delivered within the elapsed budget. No
///     action; reset the failure counter.
///   - `.throttled(elapsedMs:)` — full body delivered, but too slowly to
///     sustain real traffic. Triggers active fallback (urltest re-elect +
///     cross-process flag for the main app).
///   - `.failed(reason:)` — HTTP error or partial body. Also triggers
///     fallback, same path as throttle.
public enum TunnelProbeOutcome: Equatable {
    case healthy
    case throttled(elapsedMs: Int)
    case failed(reason: String)

    /// Convenience: did this probe round indicate the path is unusable?
    /// Healthy is false; both throttled and failed are true.
    public var isDegraded: Bool {
        switch self {
        case .healthy: return false
        case .throttled, .failed: return true
        }
    }
}

/// Thresholds for `TunnelProbeOutcomeRules.evaluate`. Encapsulates the
/// production defaults (16 KB min body, 1000 ms max elapsed for the 32 KB
/// `/api/v1/mobile/healthcheck` payload — i.e. ≥ 32 KB/s).
///
/// 32 KB/s is well below what any healthy direct/chain leg delivers under
/// normal load — the worst observed healthy line in field logs is ~83 KB/s
/// (396 ms / 32 KB). The 1000 ms cutoff therefore catches throttle without
/// triggering on transient mobile-network jitter.
public struct TunnelProbeOutcomeRules: Equatable {
    public let minBodyBytes: Int
    public let maxElapsedMs: Int

    public init(minBodyBytes: Int, maxElapsedMs: Int) {
        self.minBodyBytes = minBodyBytes
        self.maxElapsedMs = maxElapsedMs
    }

    /// Production-default rules: 16 KB min body, 1000 ms max elapsed
    /// (≥ 32 KB/s).
    public static let `default` = TunnelProbeOutcomeRules(
        minBodyBytes: 16 * 1024,
        maxElapsedMs: 1000
    )

    /// Order matters: HTTP failure > partial body > slow body > healthy.
    /// HTTP-level failure (non-2xx) means the path didn't even deliver a
    /// valid response, so we don't bother classifying the partial bytes
    /// further.
    public func evaluate(statusOK: Bool, bytesReceived: Int, elapsedMs: Int) -> TunnelProbeOutcome {
        if !statusOK {
            return .failed(reason: "http_status")
        }
        if bytesReceived < minBodyBytes {
            return .failed(reason: "partial_body_\(bytesReceived)B")
        }
        if elapsedMs > maxElapsedMs {
            return .throttled(elapsedMs: elapsedMs)
        }
        return .healthy
    }
}
