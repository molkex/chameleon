import Foundation

/// Pure, testable parsing + decision helpers for tunnel-stall detection.
///
/// Why this lives in `Shared/` (not next to `RealTrafficStallDetector` in the
/// PacketTunnel target): the detector compiles ONLY into PacketTunnel /
/// PacketTunnelMac, which the unit-test target (`@testable import MadFrogVPN`)
/// cannot see. Extracting the pure logic here — same pattern as
/// `TunnelFileLogger.truncationKeepOffset` and `SubscriptionManager.loadWithRetry`
/// — makes the stall heuristics unit-testable while the detector stays a thin
/// stateful wrapper.
///
/// DNS-STALL (2026-06-17, audit DNS-FALLBACK pivot): the detector historically
/// only ingested `connection: open connection to … : i/o timeout` lines. But the
/// dominant failure mode in the field — captured in a real iPhone log where a
/// throttled France (GRA) exit was the active leg — is the DNS path dying:
///
///     dns: exchange failed for z-p42-chat-e2ee-ig.facebook.com. IN AAAA: dial tcp 54.38.243.162:443: i/o timeout
///
/// These lines do NOT contain "open connection to", so the detector was BLIND to
/// the exact scenario that bricks the app (Instagram won't load — nothing
/// resolves). sing-box 1.13 has no DNS-server fallback (the `evaluate`/`respond`
/// actions that would allow it are 1.14+, and we're pinned to 1.13 for Xray
/// compat), so the resilience has to come from the client noticing the dead
/// resolver path and re-electing the outbound. This helper is that missing
/// signal — kept pure so it can be pinned by tests against real log lines.
enum StallSignals {

    /// Extracts the queried domain from a sing-box DNS-exchange-FAILURE line,
    /// or nil if the line isn't a resolver-path TIMEOUT.
    ///
    /// We deliberately match only timeout/deadline failures — the resolver
    /// PATH being dead — not NXDOMAIN / SERVFAIL / "server misbehaving", which
    /// mean "this particular name is bad" and must not be read as a tunnel
    /// stall (otherwise a single dead domain on a healthy tunnel would fire).
    ///
    /// sing-box decorates these lines with ANSI colour escapes and a
    /// connection-id marker, so we anchor on the unambiguous
    /// `dns: exchange failed for ` substring rather than positional parsing.
    /// The domain token sing-box prints carries a trailing FQDN dot
    /// (`facebook.com.`) which we strip.
    static func dnsFailureDomain(from message: String) -> String? {
        guard message.contains("dns: exchange failed for ") else { return nil }
        guard message.contains("i/o timeout")
            || message.contains("context deadline exceeded")
            || message.contains("operation timed out")
            || message.contains("TLS handshake timeout") else { return nil }

        guard let r = message.range(of: "dns: exchange failed for ") else { return nil }
        let after = message[r.upperBound...]
        var domain = String(after.prefix { $0 != " " && $0 != "\n" && $0 != "\t" })
        while domain.hasSuffix(".") { domain.removeLast() }
        return domain.isEmpty ? nil : domain.lowercased()
    }

    /// True when DNS resolution through the proxy is comprehensively dead:
    /// many DISTINCT domains failed to resolve in the window AND nothing dialled
    /// successfully. Both conditions matter:
    ///
    /// - `distinctFailingDomains >= minDomains` — a wide spread of names failing
    ///   means the resolver path itself is down, not one bad host. DNS failures
    ///   are not ad-noise (ad domains resolve fine when DNS works), so this is a
    ///   far higher-confidence signal than the dial-timeout heuristic and needs
    ///   no `meaningfulDownload` suppressor.
    /// - `successfulUserDials == 0` — if real connections are still completing,
    ///   DNS is at least partially working (cached IPs, .ru via dns-direct), so
    ///   we hold off and let the dial-based heuristic decide.
    static func dnsStallReached(distinctFailingDomains: Int,
                                successfulUserDials: Int,
                                minDomains: Int) -> Bool {
        distinctFailingDomains >= minDomains && successfulUserDials == 0
    }
}
