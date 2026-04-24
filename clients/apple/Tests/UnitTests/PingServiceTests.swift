import XCTest
@testable import MadFrogVPN

/// Unit tests for `PingService` — the transport-classification logic that
/// determines TCP-vs-QUIC probing. The actual network probes (`measureTCP`,
/// `measureQUIC`) are not tested here: they hit real sockets and would be
/// flaky in CI. Instead we assert the pure-function classifier that decides
/// which probe to dispatch for a given sing-box outbound `type`.
final class PingServiceTests: XCTestCase {

    // MARK: - transportFor

    func testTransportForHysteria2ReturnsQUIC() {
        XCTAssertEqual(PingService.transportFor(type: "hysteria2"), .quic)
    }

    func testTransportForTUICReturnsQUIC() {
        XCTAssertEqual(PingService.transportFor(type: "tuic"), .quic)
    }

    func testTransportForVLESSReturnsTCP() {
        XCTAssertEqual(PingService.transportFor(type: "vless"), .tcp)
    }

    func testTransportForWireguardReturnsTCP() {
        // WG is a UDP protocol but our servers don't expose WG directly to the
        // client picker — only the backend-side relay chain. If someone adds a
        // WG outbound in future, falling through to TCP is the safe default
        // (TCP handshake will fail fast rather than sending garbage UDP).
        XCTAssertEqual(PingService.transportFor(type: "wireguard"), .tcp)
    }

    func testTransportForUnknownReturnsTCP() {
        // Any unknown/future protocol should default to TCP probe — safer
        // than picking QUIC (which requires specific ALPN/handshake we may
        // not guess right for an arbitrary UDP service).
        XCTAssertEqual(PingService.transportFor(type: "shadowsocks"), .tcp)
        XCTAssertEqual(PingService.transportFor(type: "trojan"), .tcp)
        XCTAssertEqual(PingService.transportFor(type: ""), .tcp)
        XCTAssertEqual(PingService.transportFor(type: "garbage"), .tcp)
    }

    func testTransportForIsCaseInsensitive() {
        // sing-box emits lowercase type strings but backend code paths may
        // change casing (e.g. Hysteria2 in log lines). Don't regress on that.
        XCTAssertEqual(PingService.transportFor(type: "Hysteria2"), .quic)
        XCTAssertEqual(PingService.transportFor(type: "HYSTERIA2"), .quic)
        XCTAssertEqual(PingService.transportFor(type: "TUIC"), .quic)
        XCTAssertEqual(PingService.transportFor(type: "VLESS"), .tcp)
    }

    // MARK: - Cache semantics

    @MainActor
    func testLatencyForUnmeasuredTagReturnsZero() {
        let service = PingService()
        // Pristine service (cache loaded empty from UserDefaults key that
        // tests don't populate) reports 0 for any tag. 0 = "not yet measured";
        // UI renders as "— мс" rather than "0 ms".
        XCTAssertEqual(service.latency(for: "nonexistent-tag"), 0)
    }

    @MainActor
    func testLatencyReturnsCachedValueAfterManualPopulate() {
        // Exercises the read path without going through probe(). If the
        // observable `results` dictionary contains a value, latency(for:)
        // returns it unchanged.
        let service = PingService()
        service.results["de-h2-de"] = 60
        XCTAssertEqual(service.latency(for: "de-h2-de"), 60)
    }
}
