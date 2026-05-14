import XCTest
@testable import MadFrogVPN

/// test-coverage-hardening: pins the pure decision cores of the
/// Cloudflare-RU direct-IP connectivity path — load-bearing for RU
/// connectivity when OVH ASNs are blocked:
///
///  - `LegRacePlan` — the race planning + winner-selection ordering
///    extracted from `LegRaceProbe.race` (preferred fast-path → full
///    pool → empty cases).
///  - `LegRaceConfigParser` — `(tag, host, port)` extraction from the
///    sing-box config JSON, with the TCP-probable-type filter.
///  - `NetworkFingerprintLogic` — the WiFi/cellular/ethernet → coarse
///    fingerprint derivation, including branch order.
///
/// The live `NWConnection` probe / `NWPathMonitor` snapshot stay
/// on-device-verified.
final class NetworkingDecisionLogicTests: XCTestCase {

    // MARK: - LegRacePlan.firstStep — race planning

    func testFirstStep_noCandidates() {
        XCTAssertEqual(LegRacePlan.firstStep(candidateTags: [], preferred: nil), .noCandidates)
        XCTAssertEqual(LegRacePlan.firstStep(candidateTags: [], preferred: "de"), .noCandidates,
                       "no candidates → noCandidates even with a preferred tag")
    }

    func testFirstStep_preferredMatches_takesFastPath() {
        let step = LegRacePlan.firstStep(candidateTags: ["de", "nl", "de-via-msk"], preferred: "nl")
        XCTAssertEqual(step, .tryPreferredFirst(tag: "nl", timeout: LegRacePlan.preferredProbeTimeout))
    }

    func testFirstStep_preferredNotInCandidates_racesFullPool() {
        // preferred tag the user remembered no longer exists in this
        // config → no fast-path, race everything.
        let step = LegRacePlan.firstStep(candidateTags: ["de", "nl"], preferred: "gone")
        XCTAssertEqual(step, .racePool(poolTags: ["de", "nl"]))
    }

    func testFirstStep_noPreferred_racesFullPool() {
        let step = LegRacePlan.firstStep(candidateTags: ["de", "nl"], preferred: nil)
        XCTAssertEqual(step, .racePool(poolTags: ["de", "nl"]))
    }

    func testPreferredProbeTimeout_isTight() {
        // The fast-path timeout must stay tight enough to short-circuit a
        // full race within the "warm reconnect ≤ 1s" UX budget.
        XCTAssertEqual(LegRacePlan.preferredProbeTimeout, 1.2)
    }

    // MARK: - LegRacePlan.poolAfterPreferredMiss

    func testPoolAfterPreferredMiss_excludesPreferredPreservesOrder() {
        let pool = LegRacePlan.poolAfterPreferredMiss(candidateTags: ["de", "nl", "de-via-msk"], preferred: "nl")
        XCTAssertEqual(pool, ["de", "de-via-msk"], "preferred excluded, original order kept")
    }

    func testPoolAfterPreferredMiss_noPreferredKeepsAll() {
        let pool = LegRacePlan.poolAfterPreferredMiss(candidateTags: ["de", "nl"], preferred: nil)
        XCTAssertEqual(pool, ["de", "nl"])
    }

    func testPoolAfterPreferredMiss_preferredNotPresentKeepsAll() {
        let pool = LegRacePlan.poolAfterPreferredMiss(candidateTags: ["de", "nl"], preferred: "gone")
        XCTAssertEqual(pool, ["de", "nl"])
    }

    // MARK: - LegRaceConfigParser

    private func config(_ outbounds: [[String: Any]]) -> [String: Any] {
        ["outbounds": outbounds]
    }

    func testConfigParser_extractsTcpProbableCandidates() {
        let cfg = config([
            ["tag": "de", "type": "vless", "server": "1.2.3.4", "server_port": 443],
            ["tag": "nl", "type": "trojan", "server": "5.6.7.8", "server_port": 8443],
        ])
        let candidates = LegRaceConfigParser.candidates(forLegTags: ["de", "nl"], inConfigJSON: cfg)
        XCTAssertEqual(candidates, [
            LegRaceProbe.Candidate(tag: "de", host: "1.2.3.4", port: 443),
            LegRaceProbe.Candidate(tag: "nl", host: "5.6.7.8", port: 8443),
        ])
    }

    func testConfigParser_skipsUdpOnlyTypes() {
        // tuic / hysteria2 are UDP-only — TCP-handshake probing gives no
        // reliable signal, so they must be skipped.
        let cfg = config([
            ["tag": "de-tuic", "type": "tuic", "server": "1.2.3.4", "server_port": 443],
            ["tag": "de-tcp", "type": "vless", "server": "1.2.3.4", "server_port": 443],
        ])
        let candidates = LegRaceConfigParser.candidates(forLegTags: ["de-tuic", "de-tcp"], inConfigJSON: cfg)
        XCTAssertEqual(candidates.map(\.tag), ["de-tcp"])
    }

    func testConfigParser_preservesRequestedTagOrder() {
        let cfg = config([
            ["tag": "nl", "type": "vless", "server": "n", "server_port": 1],
            ["tag": "de", "type": "vless", "server": "d", "server_port": 2],
        ])
        // Requested order de,nl — result follows the requested order, not
        // the config's outbound order.
        let candidates = LegRaceConfigParser.candidates(forLegTags: ["de", "nl"], inConfigJSON: cfg)
        XCTAssertEqual(candidates.map(\.tag), ["de", "nl"])
    }

    func testConfigParser_skipsUnknownTags() {
        let cfg = config([["tag": "de", "type": "vless", "server": "d", "server_port": 1]])
        let candidates = LegRaceConfigParser.candidates(forLegTags: ["de", "missing"], inConfigJSON: cfg)
        XCTAssertEqual(candidates.map(\.tag), ["de"])
    }

    func testConfigParser_skipsEntriesMissingServerOrPort() {
        let cfg = config([
            ["tag": "noport", "type": "vless", "server": "d"],
            ["tag": "noserver", "type": "vless", "server_port": 1],
            ["tag": "ok", "type": "vless", "server": "d", "server_port": 1],
        ])
        let candidates = LegRaceConfigParser.candidates(forLegTags: ["noport", "noserver", "ok"], inConfigJSON: cfg)
        XCTAssertEqual(candidates.map(\.tag), ["ok"])
    }

    func testConfigParser_emptyWhenNoOutboundsKey() {
        XCTAssertEqual(LegRaceConfigParser.candidates(forLegTags: ["de"], inConfigJSON: [:]).count, 0)
    }

    // MARK: - NetworkFingerprintLogic.fingerprint

    func testFingerprint_wifiWithSSID() {
        let fp = NetworkFingerprintLogic.fingerprint(usesWifi: true, wifiSSID: "HomeNet", usesCellular: false, usesWiredEthernet: false)
        XCTAssertEqual(fp, "wifi:HomeNet")
    }

    func testFingerprint_wifiWithoutSSID() {
        // WiFi path but SSID unavailable (permission / macOS) → stable
        // "wifi:unknown" bucket, not nil.
        let fp = NetworkFingerprintLogic.fingerprint(usesWifi: true, wifiSSID: nil, usesCellular: false, usesWiredEthernet: false)
        XCTAssertEqual(fp, "wifi:unknown")
    }

    func testFingerprint_cellular() {
        let fp = NetworkFingerprintLogic.fingerprint(usesWifi: false, wifiSSID: nil, usesCellular: true, usesWiredEthernet: false)
        XCTAssertEqual(fp, "cellular")
    }

    func testFingerprint_ethernet() {
        let fp = NetworkFingerprintLogic.fingerprint(usesWifi: false, wifiSSID: nil, usesCellular: false, usesWiredEthernet: true)
        XCTAssertEqual(fp, "ethernet")
    }

    func testFingerprint_unknownNetworkIsNil() {
        // No identifiable interface → nil → caller treats as never-seen.
        XCTAssertNil(NetworkFingerprintLogic.fingerprint(usesWifi: false, wifiSSID: nil, usesCellular: false, usesWiredEthernet: false))
    }

    func testFingerprint_wifiWinsOverCellular() {
        // Branch order: WiFi is checked before cellular — a path that
        // reports both must fingerprint as WiFi.
        let fp = NetworkFingerprintLogic.fingerprint(usesWifi: true, wifiSSID: "X", usesCellular: true, usesWiredEthernet: false)
        XCTAssertEqual(fp, "wifi:X")
    }

    func testFingerprint_cellularWinsOverEthernet() {
        let fp = NetworkFingerprintLogic.fingerprint(usesWifi: false, wifiSSID: nil, usesCellular: true, usesWiredEthernet: true)
        XCTAssertEqual(fp, "cellular")
    }

    func testFingerprint_stableForSameInputs() {
        // Determinism — same inputs always derive the same key (it's used
        // as a cache key for "which leg worked here last time").
        let a = NetworkFingerprintLogic.fingerprint(usesWifi: true, wifiSSID: "Office", usesCellular: false, usesWiredEthernet: false)
        let b = NetworkFingerprintLogic.fingerprint(usesWifi: true, wifiSSID: "Office", usesCellular: false, usesWiredEthernet: false)
        XCTAssertEqual(a, b)
    }
}
