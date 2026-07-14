import XCTest
@testable import MadFrogVPN

final class RoutingModeTests: XCTestCase {

    // MARK: - Raw value mapping

    func testRawValueMappingForKnownStrings() {
        XCTAssertEqual(RoutingMode(rawValue: "ru-direct"), .ruDirect)
        XCTAssertEqual(RoutingMode(rawValue: "full-vpn"), .fullVPN)
    }

    func testRawValueMappingFallsBackToDefaultForGarbage() {
        // RawRepresentable returns nil for unknown values; the call site is
        // expected to use `?? .default` (RoutingMode.default = .ruDirect).
        XCTAssertNil(RoutingMode(rawValue: "garbage"))
        XCTAssertNil(RoutingMode(rawValue: ""))
        XCTAssertNil(RoutingMode(rawValue: "RU-DIRECT")) // case-sensitive
        XCTAssertNil(RoutingMode(rawValue: "ruDirect"))  // missing hyphen

        let resolved = RoutingMode(rawValue: "garbage") ?? .default
        XCTAssertEqual(resolved, .ruDirect, "default mode must be .ruDirect")
    }

    /// `smart` was retired 2026-07-14 (OOM-REFILTER). Users with it persisted in
    /// app-group defaults must migrate to a mode that still proxies unmatched
    /// traffic by default — never silently fall back to routing everything
    /// outside the tunnel.
    func testRetiredSmartModeMigratesToRUDirect() {
        XCTAssertNil(RoutingMode(rawValue: "smart"), "`smart` must no longer decode")

        let migrated = RoutingMode(rawValue: "smart") ?? .default
        XCTAssertEqual(migrated, .ruDirect)
        XCTAssertEqual(
            migrated.selectorTargets.first { $0.selector == "Default Route" }?.target,
            "Proxy",
            "a migrated smart user must not end up with Default Route = direct")
    }

    func testCaseIterableCoversTwoModes() {
        XCTAssertEqual(RoutingMode.allCases.count, 2)
        XCTAssertTrue(RoutingMode.allCases.contains(.ruDirect))
        XCTAssertTrue(RoutingMode.allCases.contains(.fullVPN))
    }

    // MARK: - Selector targets

    func testSelectorTargetsRUDirect() {
        assertTargets(RoutingMode.ruDirect.selectorTargets, ru: "direct", defaultRoute: "Proxy")
    }

    func testSelectorTargetsFullVPN() {
        assertTargets(RoutingMode.fullVPN.selectorTargets, ru: "Proxy", defaultRoute: "Proxy")
    }

    /// Every mode must proxy by default. The generated config omits "direct" from
    /// the "Default Route" selector's members precisely so this can't regress
    /// (backend/internal/vpn/clientconfig.go) — this pins the client half.
    func testEveryModeProxiesByDefault() {
        for mode in RoutingMode.allCases {
            let target = mode.selectorTargets.first { $0.selector == "Default Route" }?.target
            XCTAssertEqual(target, "Proxy", "\(mode) must route unmatched traffic through the Proxy")
        }
    }

    /// "Blocked Traffic" existed only to carry the RKN `refilter` rule-set, whose
    /// 4.8 MB in-RAM footprint oom-killed the extension. No rule references it now.
    func testAllModesUseExactlyTheKnownSelectors() {
        let knownSelectors: Set<String> = ["RU Traffic", "Default Route"]
        for mode in RoutingMode.allCases {
            let actual = Set(mode.selectorTargets.map { $0.selector })
            XCTAssertEqual(
                actual,
                knownSelectors,
                "\(mode) selector list must match the Clash API selectors")
        }
    }

    // MARK: - Helpers

    private func assertTargets(
        _ targets: [(selector: String, target: String)],
        ru: String,
        defaultRoute: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(targets.count, 2, file: file, line: line)
        let dict = Dictionary(uniqueKeysWithValues: targets.map { ($0.selector, $0.target) })
        XCTAssertEqual(dict["RU Traffic"], ru, "RU Traffic", file: file, line: line)
        XCTAssertEqual(dict["Default Route"], defaultRoute, "Default Route", file: file, line: line)
    }
}
