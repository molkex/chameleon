import XCTest
@testable import MadFrogVPN

/// test-coverage-hardening: pins resolveTunnelConfig — the config-source
/// precedence the PacketTunnel extension's startTunnel relies on
/// (extracted from ExtensionProvider so it's testable without
/// NetworkExtension). The precedence bug class this guards against:
/// a widget/On-Demand restart silently picking a stale on-disk config
/// over the fresher App-Group-persisted one.
final class TunnelConfigSourceTests: XCTestCase {

    func testOptionsWins() {
        let r = resolveTunnelConfig(options: "OPTS", persisted: "PERS", file: "FILE")
        XCTAssertEqual(r, ResolvedTunnelConfig(json: "OPTS", source: .options),
                       "tunnel options are the freshest source — they must win")
    }

    func testPersistedWinsWhenNoOptions() {
        let r = resolveTunnelConfig(options: nil, persisted: "PERS", file: "FILE")
        XCTAssertEqual(r, ResolvedTunnelConfig(json: "PERS", source: .persisted),
                       "App-Group-persisted config is the warm path — beats the on-disk file")
    }

    func testFileIsLastResort() {
        let r = resolveTunnelConfig(options: nil, persisted: nil, file: "FILE")
        XCTAssertEqual(r, ResolvedTunnelConfig(json: "FILE", source: .file))
    }

    func testNilWhenNoSource() {
        XCTAssertNil(resolveTunnelConfig(options: nil, persisted: nil, file: nil),
                     "no source at all → nil → caller fails the start with 'No VPN config'")
    }

    func testFileNotReadWhenOptionsWins() {
        var fileRead = false
        func readFile() -> String? { fileRead = true; return "FILE" }
        _ = resolveTunnelConfig(options: "OPTS", persisted: nil, file: readFile())
        XCTAssertFalse(fileRead, "the @autoclosure file source must not be read when options wins")
    }

    func testFileNotReadWhenPersistedWins() {
        var fileRead = false
        func readFile() -> String? { fileRead = true; return "FILE" }
        _ = resolveTunnelConfig(options: nil, persisted: "PERS", file: readFile())
        XCTAssertFalse(fileRead, "the warm path (persisted hit) must do no on-disk I/O")
    }

    func testFileIsReadWhenItIsTheOnlySource() {
        var fileRead = false
        func readFile() -> String? { fileRead = true; return "FILE" }
        let r = resolveTunnelConfig(options: nil, persisted: nil, file: readFile())
        XCTAssertTrue(fileRead)
        XCTAssertEqual(r?.source, .file)
    }
}
