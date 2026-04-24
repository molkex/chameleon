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
        // expected to use `?? .default` (RoutingMode.default = .fullVPN).
        XCTAssertNil(RoutingMode(rawValue: "garbage"))
        XCTAssertNil(RoutingMode(rawValue: ""))
        XCTAssertNil(RoutingMode(rawValue: "SMART"))   // case-sensitive
        XCTAssertNil(RoutingMode(rawValue: "ruDirect")) // missing hyphen

        let resolved = RoutingMode(rawValue: "garbage") ?? .default
        XCTAssertEqual(resolved, .fullVPN, "default mode must be .fullVPN")
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
