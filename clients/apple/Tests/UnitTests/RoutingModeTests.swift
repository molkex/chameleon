import XCTest
@testable import MadFrogVPN

final class RoutingModeTests: XCTestCase {

    // MARK: - Raw value mapping

    func testRawValueMappingForKnownStrings() {
        XCTAssertEqual(RoutingMode(rawValue: "smart"), .smart)
        XCTAssertEqual(RoutingMode(rawValue: "ru-direct"), .ruDirect)
        XCTAssertEqual(RoutingMode(rawValue: "full-vpn"), .fullVPN)
    }

    func testRawValueMappingFallsBackToDefaultForGarbage() {
        // RawRepresentable returns nil for unknown values; the call site is
        // expected to use `?? .default`.
        XCTAssertNil(RoutingMode(rawValue: "garbage"))
        XCTAssertNil(RoutingMode(rawValue: ""))
        XCTAssertNil(RoutingMode(rawValue: "SMART"))   // case-sensitive
        XCTAssertNil(RoutingMode(rawValue: "ruDirect")) // missing hyphen

        let resolved = RoutingMode(rawValue: "garbage") ?? .default
        // Build 58 (2026-05-13): default changed .fullVPN → .ruDirect.
        // Field log 5:48 PM showed users picking "Умный" expecting it to be
        // optimal — actually it bypasses VPN for most apps, breaking Telegram
        // and Speedtest on cellular where carriers throttle direct flows.
        // .ruDirect (split-tunnel) is the balanced default: .ru sites stay
        // fast (direct), everything else gets the VPN's protection.
        XCTAssertEqual(resolved, .ruDirect, "default mode must be .ruDirect for new users")
    }

    // MARK: - Recommendation surface

    /// Build 58: explicit `recommended` static accessor so UI can surface
    /// a "рекомендуем" badge next to the right segment. Same value as
    /// `default` today; kept separate so we can A/B them independently
    /// later (e.g. recommend ruDirect while default-on-install stays
    /// fullVPN for travellers).
    func testRecommendedModeIsRuDirect() {
        XCTAssertEqual(RoutingMode.recommended, .ruDirect)
    }

    func testDefaultEqualsRecommendedForNow() {
        // We tie default to recommended on build 58. Diverge only when we
        // have data that justifies a split.
        XCTAssertEqual(RoutingMode.default, RoutingMode.recommended)
    }

    func testCaseIterableCoversThreeModes() {
        XCTAssertEqual(RoutingMode.allCases.count, 3)
        XCTAssertTrue(RoutingMode.allCases.contains(.smart))
        XCTAssertTrue(RoutingMode.allCases.contains(.ruDirect))
        XCTAssertTrue(RoutingMode.allCases.contains(.fullVPN))
    }

    // MARK: - Selector targets

    func testSelectorTargetsSmart() {
        let targets = RoutingMode.smart.selectorTargets
        XCTAssertEqual(targets.count, 3)
        assertTriple(
            targets,
            ru: "direct",
            blocked: "Proxy",
            defaultRoute: "direct"
        )
    }

    func testSelectorTargetsRUDirect() {
        let targets = RoutingMode.ruDirect.selectorTargets
        XCTAssertEqual(targets.count, 3)
        assertTriple(
            targets,
            ru: "direct",
            blocked: "Proxy",
            defaultRoute: "Proxy"
        )
    }

    func testSelectorTargetsFullVPN() {
        let targets = RoutingMode.fullVPN.selectorTargets
        XCTAssertEqual(targets.count, 3)
        assertTriple(
            targets,
            ru: "Proxy",
            blocked: "Proxy",
            defaultRoute: "Proxy"
        )
    }

    func testAllModesUseExactlyTheKnownSelectors() {
        let knownSelectors: Set<String> = ["RU Traffic", "Blocked Traffic", "Default Route"]
        for mode in RoutingMode.allCases {
            let actual = Set(mode.selectorTargets.map { $0.selector })
            XCTAssertEqual(
                actual,
                knownSelectors,
                "\(mode) selector list must match the three Clash API selectors")
        }
    }

    // MARK: - Helpers

    private func assertTriple(
        _ triple: [(selector: String, target: String)],
        ru: String,
        blocked: String,
        defaultRoute: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let dict = Dictionary(uniqueKeysWithValues: triple.map { ($0.selector, $0.target) })
        XCTAssertEqual(dict["RU Traffic"], ru, "RU Traffic", file: file, line: line)
        XCTAssertEqual(dict["Blocked Traffic"], blocked, "Blocked Traffic", file: file, line: line)
        XCTAssertEqual(dict["Default Route"], defaultRoute, "Default Route", file: file, line: line)
    }
}
