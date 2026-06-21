import XCTest
@testable import MadFrogVPN

/// DNS-stall signal (2026-06-17, audit DNS-FALLBACK pivot). Pins the pure
/// parsing + decision seam that teaches RealTrafficStallDetector to see the
/// resolver-path death it was previously blind to. Lines below are verbatim
/// from a real iPhone tunnel-debug log where a throttled France (GRA,
/// 54.38.243.162) exit was the active leg and Instagram/Apple services failed
/// to load because DNS through the dead proxy timed out 600+ times.
final class StallSignalsTests: XCTestCase {

    // ANSI/connection-id decorated, exactly as sing-box emits to writeLogs.
    private let igLine = "\u{1b}[31mERROR\u{1b}[0m[0058] [\u{1b}[38;5;185m538926505\u{1b}[0m 26.56s] dns: exchange failed for z-p42-chat-e2ee-ig.facebook.com. IN AAAA: dial tcp 54.38.243.162:443: i/o timeout"
    private let appleLine = "dns: exchange failed for gspe79-ssl.ls.apple.com. IN HTTPS: dial tcp 54.38.243.162:443: i/o timeout"
    private let deadlineLine = "dns: exchange failed for edge-mqtt-fallback.facebook.com. IN A: context deadline exceeded"

    func testParsesDomainFromRealTimeoutLines() {
        XCTAssertEqual(StallSignals.dnsFailureDomain(from: igLine), "z-p42-chat-e2ee-ig.facebook.com")
        XCTAssertEqual(StallSignals.dnsFailureDomain(from: appleLine), "gspe79-ssl.ls.apple.com")
        XCTAssertEqual(StallSignals.dnsFailureDomain(from: deadlineLine), "edge-mqtt-fallback.facebook.com")
    }

    // Real b122 on-device log (2026-06-21): a ~1-min "sites won't load" was 49 DNS
    // failures with "use of closed network connection" to the MSK relay (:2097/:2099)
    // — the relay leg dropped mid-read. The detector MUST count these as resolver-path
    // death (it didn't before, so no recovery fired). Regression guard for that fix.
    func testParsesRelayDroppedDNSFailures() {
        let closed = "\u{1b}[31mERROR\u{1b}[0m[0067] [70431940 1.34s] dns: exchange failed for x.com. IN A: read tcp 100.84.24.63:58486->217.198.5.52:2099: use of closed network connection"
        let reset  = "dns: exchange failed for app.squareup.com. IN AAAA: read tcp 100.84.24.63:58486->217.198.5.52:2097: connection reset by peer"
        XCTAssertEqual(StallSignals.dnsFailureDomain(from: closed), "x.com")
        XCTAssertEqual(StallSignals.dnsFailureDomain(from: reset), "app.squareup.com")
    }

    func testStripsTrailingFQDNDotAndLowercases() {
        let line = "dns: exchange failed for API.Instagram.COM. IN A: operation timed out"
        XCTAssertEqual(StallSignals.dnsFailureDomain(from: line), "api.instagram.com")
    }

    func testIgnoresNonTimeoutDNSFailures() {
        // NXDOMAIN / SERVFAIL = "this name is bad", NOT a dead resolver path.
        let nx = "dns: exchange failed for nonexistent.example. IN A: NXDOMAIN"
        let servfail = "dns: exchange failed for foo.example. IN A: server misbehaving"
        XCTAssertNil(StallSignals.dnsFailureDomain(from: nx))
        XCTAssertNil(StallSignals.dnsFailureDomain(from: servfail))
    }

    func testIgnoresNonDNSLines() {
        // A connection-dial timeout (handled by the OTHER detector branch).
        let dial = "connection: open connection to 157.240.214.63:443 using outbound/vless[fr-direct-gra1]: dial tcp 54.38.243.162:443: i/o timeout"
        let info = "inbound/tun[tun-in]: inbound packet connection to 157.240.214.63:443"
        XCTAssertNil(StallSignals.dnsFailureDomain(from: dial))
        XCTAssertNil(StallSignals.dnsFailureDomain(from: info))
    }

    // MARK: - OOM-SELF-HEAL

    func testDetectsOOMKillerResetLine() {
        // Verbatim from the field log (resident hit 83 MB; fired 39× in one capture).
        let line = "\u{1b}[31mERROR\u{1b}[0m[20007] service/oom-killer[0]: memory pressure: critical, usage: 40 MiB, resetting network"
        XCTAssertTrue(StallSignals.isMemoryPressureReset(line))
    }

    func testOOMMatchRequiresBothPressureAndReset() {
        // "resetting network" alone (e.g. a manual reload) is not an oom event.
        XCTAssertFalse(StallSignals.isMemoryPressureReset("network: resetting network after config reload"))
        // A memory log without the reset action is not the trigger either.
        XCTAssertFalse(StallSignals.isMemoryPressureReset("memory: phys=39MB resident=58MB avail=10MB"))
        // Unrelated line.
        XCTAssertFalse(StallSignals.isMemoryPressureReset("inbound/tun[tun-in]: inbound packet connection to 1.2.3.4:443"))
    }

    func testDNSStallDecisionTruthTable() {
        // Wide spread of failing names + nothing dialling = dead resolver path.
        XCTAssertTrue(StallSignals.dnsStallReached(distinctFailingDomains: 8, successfulUserDials: 0, minDomains: 8))
        XCTAssertTrue(StallSignals.dnsStallReached(distinctFailingDomains: 20, successfulUserDials: 0, minDomains: 8))
        // Below the spread threshold — could be a couple of flaky names.
        XCTAssertFalse(StallSignals.dnsStallReached(distinctFailingDomains: 7, successfulUserDials: 0, minDomains: 8))
        // Data is still flowing somewhere — DNS is at least partially alive.
        XCTAssertFalse(StallSignals.dnsStallReached(distinctFailingDomains: 12, successfulUserDials: 3, minDomains: 8))
    }
}
