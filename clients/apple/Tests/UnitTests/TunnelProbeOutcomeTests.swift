import XCTest
@testable import MadFrogVPN

/// Tests for `TunnelProbeOutcomeRules` — the pure data-plane health decision
/// the PacketTunnel extension uses to translate (HTTP status, body bytes,
/// elapsed ms) into a healthy / throttled / failed classification.
///
/// Field log 2026-05-13 motivated build 57: a 32 KB body that arrives in
/// 1.3-1.6 seconds (= 20-25 KB/s) currently counts as "OK" because the
/// build-42 check only validates byte count, ignoring time. Speedtest fails
/// and Telegram media stalls under such throttle. The new rules promote
/// elapsed time to a first-class signal.
final class TunnelProbeOutcomeTests: XCTestCase {

    /// Defaults mirror the production TunnelStallProbe.Config — 16 KB min
    /// body, 1000 ms max elapsed for a 32 KB body (= 32 KB/s minimum).
    private let rules = TunnelProbeOutcomeRules(
        minBodyBytes: 16 * 1024,
        maxElapsedMs: 1000
    )

    func testFastSuccessIsHealthy() {
        // Field log baseline: 470 ms / 32 KB = ~70 KB/s.
        let outcome = rules.evaluate(statusOK: true, bytesReceived: 32 * 1024, elapsedMs: 470)
        XCTAssertEqual(outcome, .healthy)
    }

    func testThrottledBodyIsThrottled() {
        // Field log throttle: 1302 ms / 32 KB = ~25 KB/s. Bytes complete but
        // far too slow for real traffic (Telegram media, Speedtest).
        let outcome = rules.evaluate(statusOK: true, bytesReceived: 32 * 1024, elapsedMs: 1302)
        XCTAssertEqual(outcome, .throttled(elapsedMs: 1302))
    }

    func testWorseThrottleIsStillThrottled() {
        // Field log: 1654 ms / 32 KB = ~20 KB/s. Even slower.
        let outcome = rules.evaluate(statusOK: true, bytesReceived: 32 * 1024, elapsedMs: 1654)
        XCTAssertEqual(outcome, .throttled(elapsedMs: 1654))
    }

    func testHttpFailureIsFailed() {
        // 5xx / 4xx response → not a throttle, hard fail.
        let outcome = rules.evaluate(statusOK: false, bytesReceived: 0, elapsedMs: 50)
        if case .failed = outcome {} else {
            XCTFail("non-2xx should be .failed, got \(outcome)")
        }
    }

    func testPartialBodyIsFailed() {
        // TLS handshake succeeded but only 8 KB came through — classic
        // mid-flight kill. Distinct from throttle (which delivers the full
        // body, just slowly).
        let outcome = rules.evaluate(statusOK: true, bytesReceived: 8 * 1024, elapsedMs: 500)
        if case .failed = outcome {} else {
            XCTFail("partial body should be .failed, got \(outcome)")
        }
    }

    func testExactlyAtBodyThresholdIsHealthy() {
        // 16 KB exactly + fast = healthy (>= comparison, not >).
        let outcome = rules.evaluate(statusOK: true, bytesReceived: 16 * 1024, elapsedMs: 400)
        XCTAssertEqual(outcome, .healthy)
    }

    func testExactlyAtElapsedThresholdIsHealthy() {
        // 1000 ms is the inclusive upper bound — anything > is throttled.
        let outcome = rules.evaluate(statusOK: true, bytesReceived: 32 * 1024, elapsedMs: 1000)
        XCTAssertEqual(outcome, .healthy)
    }

    func testOneMsAboveElapsedThresholdIsThrottled() {
        let outcome = rules.evaluate(statusOK: true, bytesReceived: 32 * 1024, elapsedMs: 1001)
        XCTAssertEqual(outcome, .throttled(elapsedMs: 1001))
    }

    func testCustomRulesHonoured() {
        // Tight rules: 4 KB min body, 200 ms max elapsed. Probe of 4 KB in
        // 150 ms should be healthy.
        let tight = TunnelProbeOutcomeRules(minBodyBytes: 4 * 1024, maxElapsedMs: 200)
        XCTAssertEqual(tight.evaluate(statusOK: true, bytesReceived: 4 * 1024, elapsedMs: 150), .healthy)
        XCTAssertEqual(tight.evaluate(statusOK: true, bytesReceived: 4 * 1024, elapsedMs: 250), .throttled(elapsedMs: 250))
    }
}
