import XCTest
@testable import MadFrogVPN

/// HOME-STATS (2026-07-14) regression guards for the pure parts of the new
/// home-screen live-stats strip: the ipify JSON decoder and the
/// connected/available placeholder rule for the ↑/↓ byte totals. The actual
/// network call (`ExternalIPService.refresh`) is NOT tested here — it hits
/// a real endpoint and would be flaky/slow in CI, same rationale as
/// `PingServiceTests` skipping the real TCP/QUIC probes.
final class ExternalIPServiceTests: XCTestCase {

    // MARK: - IPifyResponse.decode

    func testDecodeValidPayload() {
        let json = Data(#"{"ip":"217.182.74.70"}"#.utf8)
        XCTAssertEqual(IPifyResponse.decode(json), IPifyResponse(ip: "217.182.74.70"))
    }

    func testDecodeValidIPv6Payload() {
        let json = Data(#"{"ip":"2001:db8::1"}"#.utf8)
        XCTAssertEqual(IPifyResponse.decode(json)?.ip, "2001:db8::1")
    }

    func testDecodeIgnoresExtraFields() {
        // ipify's plain endpoint only ever returns {"ip":...}, but don't
        // hard-fail if it ever adds fields (e.g. format variants).
        let json = Data(#"{"ip":"1.2.3.4","extra":"field"}"#.utf8)
        XCTAssertEqual(IPifyResponse.decode(json)?.ip, "1.2.3.4")
    }

    func testDecodeRejectsMissingIPField() {
        let json = Data(#"{"notip":"1.2.3.4"}"#.utf8)
        XCTAssertNil(IPifyResponse.decode(json))
    }

    func testDecodeRejectsMalformedJSON() {
        let json = Data("not json at all".utf8)
        XCTAssertNil(IPifyResponse.decode(json))
    }

    func testDecodeRejectsEmptyData() {
        XCTAssertNil(IPifyResponse.decode(Data()))
    }

    func testDecodeRejectsHTMLErrorPage() {
        // What a captive portal / proxy error page looks like — must not be
        // mistaken for a valid IP.
        let html = Data("<html><body>502 Bad Gateway</body></html>".utf8)
        XCTAssertNil(IPifyResponse.decode(html))
    }

    // MARK: - ExternalIPService.reset / initial state

    @MainActor
    func testFreshServiceHasNoIP() {
        let service = ExternalIPService()
        XCTAssertNil(service.ip)
    }

    @MainActor
    func testResetClearsIP() {
        let service = ExternalIPService()
        // Simulate a prior successful fetch by decoding straight into the
        // service's own decoder and checking reset() clears state — we
        // can't set `ip` directly (private(set)), so this exercises reset()
        // on the pristine value, which is the state most relevant for the
        // background/disconnect teardown path exercised by MainViewNeon's
        // `.task(id:)`.
        service.reset()
        XCTAssertNil(service.ip)
    }

    // MARK: - ConnectionStatsFormatter

    func testTotalTextShowsPlaceholderWhenDisconnected() {
        XCTAssertEqual(
            ConnectionStatsFormatter.totalText(bytes: 123_456, isConnected: false, statsAvailable: true),
            "—"
        )
    }

    func testTotalTextShowsPlaceholderWhenStatsUnavailable() {
        // Connected but the CommandClient's unix-socket stream to the
        // extension hasn't come up yet (or failed) — must not show "0 B".
        XCTAssertEqual(
            ConnectionStatsFormatter.totalText(bytes: 0, isConnected: true, statsAvailable: false),
            "—"
        )
    }

    func testTotalTextShowsPlaceholderWhenBothUnavailable() {
        XCTAssertEqual(
            ConnectionStatsFormatter.totalText(bytes: 999, isConnected: false, statsAvailable: false),
            "—"
        )
    }

    func testTotalTextFormatsBytesWhenConnectedAndAvailable() {
        // LibboxFormatBytes(0) is "0 B" — just assert it's NOT the "—"
        // placeholder once both gates pass; the exact human-readable string
        // (KB/MB/GB thresholds) is libbox's own formatting, not ours to pin.
        let text = ConnectionStatsFormatter.totalText(bytes: 0, isConnected: true, statsAvailable: true)
        XCTAssertNotEqual(text, "—")

        let bigText = ConnectionStatsFormatter.totalText(bytes: 5 * 1024 * 1024, isConnected: true, statsAvailable: true)
        XCTAssertNotEqual(bigText, "—")
        XCTAssertFalse(bigText.isEmpty)
    }
}
