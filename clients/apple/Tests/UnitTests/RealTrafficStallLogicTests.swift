import XCTest
@testable import MadFrogVPN

/// test-coverage-hardening: pins `RealTrafficStallLogic` — the pure
/// log-parsing + sliding-window + multi-criteria STALL formula extracted
/// from `PacketTunnel/RealTrafficStallDetector.swift` (the PacketTunnel
/// extension target can't be linked from the test bundle).
///
/// What this guards:
///  - sing-box log-line classification + parsing (outbound tag through
///    ANSI/connection-id bracket noise, destination host extraction,
///    urltest-probe exclusion).
///  - the sliding-window prune (events older than the window dropped).
///  - the STALL criteria chain: minAttempts → minTimeouts → rate →
///    distinctDests → meaningful-download suppressor — and crucially
///    that it does NOT fire on healthy traffic.
///
/// The detector's DispatchQueue / ring-buffer storage / cooldown /
/// per-hour cap stay on-device-verified.
final class RealTrafficStallLogicTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private typealias L = RealTrafficStallLogic

    // MARK: - Log-line classification

    func testClassification_dialFailureLines() {
        let cases: [(String, Bool)] = [
            ("connection: open connection to 95.161.76.100:5222 using outbound/vless[de-direct-de]: dial tcp 1.2.3.4:443: i/o timeout", true),
            ("connection: open connection to 23.3.91.165:443 using outbound/vless[de]: read tcp x->y: operation timed out", true),
            ("connection: open connection to 1.1.1.1:443 using outbound/vless[de]: context deadline exceeded", true),
            ("connection: open connection to 1.1.1.1:443 using outbound/vless[de]: TLS handshake timeout", true),
            // open connection but a non-timeout error → not a failure line
            ("connection: open connection to 1.1.1.1:443 using outbound/vless[de]: connection refused", false),
            // timeout substring but not an "open connection" line
            ("dns: i/o timeout", false),
            ("router: route matched", false),
        ]
        for (msg, expected) in cases {
            XCTAssertEqual(L.isUserDialFailureLine(msg), expected, "classification of: \(msg)")
        }
    }

    func testClassification_dialSuccessLines() {
        XCTAssertTrue(L.isDialSuccessLine("outbound/vless[de-direct-de]: outbound connection to 142.1.2.3:443"))
        XCTAssertFalse(L.isDialSuccessLine("connection: open connection to 1.1.1.1:443 using outbound/vless[de]: i/o timeout"))
        XCTAssertFalse(L.isDialSuccessLine("router: route matched"))
    }

    // MARK: - parseUserDialFailure

    func testParseFailure_extractsOutboundAndDestination() {
        let msg = "connection: open connection to facebook.com:443 using outbound/vless[de-direct-de]: dial tcp 162.19.242.30:443: i/o timeout"
        let dial = L.parseUserDialFailure(from: msg, at: t0)
        XCTAssertEqual(dial?.outbound, "de-direct-de")
        XCTAssertEqual(dial?.destination, "facebook.com", "port must be stripped — distinct dests count by host")
        XCTAssertEqual(dial?.isTimeout, true)
        XCTAssertEqual(dial?.timestamp, t0)
    }

    func testParseFailure_survivesAnsiAndConnectionIdBrackets() {
        // sing-box sprinkles ANSI colour escapes and connection-id markers
        // with stray brackets — the FIRST '[' is not the outbound tag's.
        let msg = "\u{1b}[31mERROR\u{1b}[0m [[38;5;101m1915784021[0m 2m7s] connection: open connection to 23.3.91.165:443 using outbound/vless[nl-via-msk]: dial tcp 1.2.3.4:443: i/o timeout"
        let dial = L.parseUserDialFailure(from: msg, at: t0)
        XCTAssertEqual(dial?.outbound, "nl-via-msk", "must anchor on 'using outbound/', not the first bracket")
        XCTAssertEqual(dial?.destination, "23.3.91.165")
    }

    func testParseFailure_ipv6DestinationStripsLastColonPort() {
        // lastIndex(of: ":") on an IPv6 literal strips at the port colon.
        let msg = "connection: open connection to [2001:db8::1]:443 using outbound/vless[de]: i/o timeout"
        let dial = L.parseUserDialFailure(from: msg, at: t0)
        XCTAssertEqual(dial?.destination, "[2001:db8::1]")
    }

    func testParseFailure_nilWhenNoOutboundAnchor() {
        XCTAssertNil(L.parseUserDialFailure(from: "connection: open connection to host:443: i/o timeout", at: t0))
    }

    // MARK: - parseDialSuccess

    func testParseSuccess_extractsOutboundAndDestination() {
        let msg = "outbound/vless[de-direct-de]: outbound connection to 142.250.1.2:443"
        let dial = L.parseDialSuccess(from: msg, at: t0)
        XCTAssertEqual(dial?.outbound, "de-direct-de")
        XCTAssertEqual(dial?.destination, "142.250.1.2")
        XCTAssertEqual(dial?.isTimeout, false)
    }

    func testParseSuccess_excludesUrltestProbe() {
        // urltest probe successes must NOT pad the failure-ratio
        // denominator — they're sing-box's own probe, not user traffic.
        let msg = "outbound/urltest[auto]: outbound connection to www.gstatic.com:443"
        XCTAssertNil(L.parseDialSuccess(from: msg, at: t0))
    }

    func testParseSuccess_nilWhenNoOutboundAnchor() {
        XCTAssertNil(L.parseDialSuccess(from: "router: connection to 1.2.3.4:443", at: t0))
    }

    // MARK: - Sliding-window prune

    func testPrune_dropsEventsOlderThanWindow() {
        let events = [
            L.DialAttempt(timestamp: t0.addingTimeInterval(-40), outbound: "a", destination: "x", isTimeout: true),
            L.DialAttempt(timestamp: t0.addingTimeInterval(-29), outbound: "a", destination: "y", isTimeout: true),
            L.DialAttempt(timestamp: t0, outbound: "a", destination: "z", isTimeout: true),
        ]
        let kept = L.pruned(events, windowSeconds: 30, referenceDate: t0, timestamp: { $0.timestamp })
        XCTAssertEqual(kept.count, 2, "the -40s event is outside the 30s window")
        XCTAssertEqual(kept.map(\.destination), ["y", "z"])
    }

    func testPrune_boundaryIsInclusive() {
        // cutoff = referenceDate - window; events at exactly the cutoff
        // are kept (>= cutoff).
        let events = [L.DialAttempt(timestamp: t0.addingTimeInterval(-30), outbound: "a", destination: "x", isTimeout: true)]
        XCTAssertEqual(L.pruned(events, windowSeconds: 30, referenceDate: t0, timestamp: { $0.timestamp }).count, 1)
    }

    // MARK: - evaluate — the STALL criteria chain

    /// Build `count` timeout dials across `distinctDests` distinct hosts.
    private func timeouts(_ count: Int, distinctDests: Int) -> [L.DialAttempt] {
        (0..<count).map { i in
            L.DialAttempt(timestamp: t0, outbound: "de", destination: "host\(i % distinctDests)", isTimeout: true)
        }
    }

    private func successes(_ count: Int) -> [L.DialAttempt] {
        (0..<count).map { i in
            L.DialAttempt(timestamp: t0, outbound: "de", destination: "ok\(i)", isTimeout: false)
        }
    }

    func testEvaluate_firesStallWhenAllCriteriaMet() {
        // 10 attempts, 8 timeouts (rate 0.8 ≥ 0.6), 4 distinct dests, no download.
        let dials = timeouts(8, distinctDests: 4) + successes(2)
        let decision = L.evaluate(recentDials: dials, recentCloses: [], thresholds: L.Thresholds())
        XCTAssertEqual(decision, .stall)
    }

    func testEvaluate_doesNotFireOnHealthyTraffic() {
        // 20 successful dials, zero timeouts — the explicit "must NOT
        // fire on healthy traffic" requirement.
        let decision = L.evaluate(recentDials: successes(20), recentCloses: [], thresholds: L.Thresholds())
        XCTAssertEqual(decision, .notEnoughTimeouts)
    }

    func testEvaluate_doesNotFireWhenIdle() {
        // Idle tunnel — zero attempts must never trigger STALL.
        let decision = L.evaluate(recentDials: [], recentCloses: [], thresholds: L.Thresholds())
        XCTAssertEqual(decision, .notEnoughAttempts)
    }

    func testEvaluate_belowMinAttempts() {
        // 7 attempts, all timeouts — fails minAttempts (8) before anything else.
        let decision = L.evaluate(recentDials: timeouts(7, distinctDests: 7), recentCloses: [], thresholds: L.Thresholds())
        XCTAssertEqual(decision, .notEnoughAttempts)
    }

    func testEvaluate_belowMinTimeouts() {
        // 8 attempts, only 4 timeouts — fails minTimeouts (5).
        let dials = timeouts(4, distinctDests: 4) + successes(4)
        let decision = L.evaluate(recentDials: dials, recentCloses: [], thresholds: L.Thresholds())
        XCTAssertEqual(decision, .notEnoughTimeouts)
    }

    func testEvaluate_rateTooLow() {
        // 12 attempts, 5 timeouts → rate 0.416 < 0.6. Real data flowing
        // among the failures → ratio falls below threshold naturally.
        let dials = timeouts(5, distinctDests: 5) + successes(7)
        let decision = L.evaluate(recentDials: dials, recentCloses: [], thresholds: L.Thresholds())
        XCTAssertEqual(decision, .rateTooLow)
    }

    func testEvaluate_oneBadHostDoesNotTrigger() {
        // 10 timeouts but all to ONE destination → host-specific, not
        // tunnel-wide. distinctDests (1) < minDistinctDestinations (3).
        let dials = timeouts(10, distinctDests: 1)
        let decision = L.evaluate(recentDials: dials, recentCloses: [], thresholds: L.Thresholds())
        XCTAssertEqual(decision, .tooFewDistinctDests)
    }

    func testEvaluate_meaningfulDownloadSuppressesStall() {
        // All STALL criteria met, BUT a connection closed in-window with
        // ≥ 4096 downlink bytes → tunnel is moving real data, suppress.
        let dials = timeouts(8, distinctDests: 4) + successes(2)
        let closes = [L.ConnectionClose(timestamp: t0, downloadBytes: 4096)]
        let decision = L.evaluate(recentDials: dials, recentCloses: closes, thresholds: L.Thresholds())
        XCTAssertEqual(decision, .meaningfulDownload)
    }

    func testEvaluate_smallDownloadDoesNotSuppress() {
        // A close with 4095 bytes (just under threshold) does NOT suppress.
        let dials = timeouts(8, distinctDests: 4) + successes(2)
        let closes = [L.ConnectionClose(timestamp: t0, downloadBytes: 4095)]
        let decision = L.evaluate(recentDials: dials, recentCloses: closes, thresholds: L.Thresholds())
        XCTAssertEqual(decision, .stall)
    }

    func testEvaluate_emptyDestinationsNotCountedAsDistinct() {
        // Timeout dials with empty destination strings don't pad the
        // distinct-dest set. 8 timeouts all empty-dest → 0 distinct.
        let dials = (0..<8).map { _ in
            L.DialAttempt(timestamp: t0, outbound: "de", destination: "", isTimeout: true)
        }
        let decision = L.evaluate(recentDials: dials, recentCloses: [], thresholds: L.Thresholds())
        XCTAssertEqual(decision, .tooFewDistinctDests)
    }

    func testEvaluate_rateBoundaryExactlyAtThreshold() {
        // rate == minTimeoutRate (0.6) passes (>=). 10 attempts, 6 timeouts.
        let dials = timeouts(6, distinctDests: 3) + successes(4)
        let decision = L.evaluate(recentDials: dials, recentCloses: [], thresholds: L.Thresholds())
        XCTAssertEqual(decision, .stall)
    }
}
